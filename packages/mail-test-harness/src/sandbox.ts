import type { ChildProcess } from 'node:child_process';

import { spawn } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import {
  mkdir,
  open,
  readFile,
  realpath,
  rm,
  stat,
  writeFile,
} from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';

import type { MailEndpoints } from './harness.ts';
import type { OwnedSimulator, OwnedSimulatorIntent } from './ownership.ts';

import {
  createNamedMailTestSimulator,
  deleteOwnedSimulator,
  deleteOwnedSimulatorIntent,
  launchManualMailTestApplication,
  prepareMailTestSimulator,
  resetManualMailTestApplication,
} from './apple.ts';
import { resolveGreenMailArtifact } from './artifact.ts';
import {
  MAILBOX_EMAIL,
  MAILBOX_PASSWORD,
  allocateMailEndpoints,
  generateCertificate,
  syntheticMessage,
  verifyJavaToolchain,
  waitForGreenMailReadiness,
  writeJavaArguments,
} from './harness.ts';
import { runCommand, terminateProcess } from './process.ts';
import { sendSMTPSMessage } from './protocol.ts';

const SANDBOX_KIND = 'manual-mail-sandbox';
const SANDBOX_SCENARIO = 'core-mail-loop';
const OWNERSHIP_FILE = 'sandbox.json';
const SIMULATOR_NAME_PREFIX = 'Unwired Mail Manual Sandbox';
const FIXTURE_MESSAGE_ID = 'manual-core-mail-loop@synthetic.invalid';
const FIXTURE_SUBJECT = 'Manual Mail Sandbox';
const FIXTURE_BODY = 'Synthetic message for the Manual Mail Sandbox.';
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

type SandboxAction = 'injected' | 'reset' | 'started' | 'status' | 'stopped';
type SandboxStatus = 'running' | 'stale' | 'stopped';

export interface ManualSandboxRecord {
  createdAt: string;
  kind: typeof SANDBOX_KIND;
  process: null | {
    commandMarker: string;
    pid: number;
  };
  resources: {
    endpoints: MailEndpoints;
    paths: string[];
    simulator: null | OwnedSimulator;
    simulatorIntent: OwnedSimulatorIntent;
  };
  root: string;
  runId: string;
  scenario: typeof SANDBOX_SCENARIO;
  schemaVersion: 1;
  token: string;
}

export interface ManualSandboxEvidence {
  action: SandboxAction;
  endpoints?: {
    imaps: { host: '127.0.0.1'; port: number };
    smtps: { host: '127.0.0.1'; port: number };
  };
  kind: typeof SANDBOX_KIND;
  processId?: number;
  runId?: string;
  scenario: typeof SANDBOX_SCENARIO;
  schemaVersion: 1;
  simulator?: OwnedSimulator;
  status: SandboxStatus;
}

function manualSandboxRoot(): string {
  return path.join(homedir(), '.cache', 'unwired-mail-test', 'manual-sandbox');
}

export async function startManualSandbox(
  signal?: AbortSignal,
  root?: string,
): Promise<ManualSandboxEvidence> {
  signal?.throwIfAborted();
  const sandboxRoot = await resolveManualSandboxRoot(root);
  if (await pathExists(sandboxRoot)) {
    throw new Error(
      'Manual Mail Sandbox already exists. Run `pnpm mail:test sandbox status` or `pnpm mail:test sandbox stop`.',
    );
  }
  const artifact = await resolveGreenMailArtifact({ signal });
  await verifyJavaToolchain(signal);
  const endpoints = await allocateMailEndpoints();
  await mkdir(path.dirname(sandboxRoot), { mode: 0o700, recursive: true });
  await mkdir(sandboxRoot, { mode: 0o700 });
  const resolvedRoot = await realpath(sandboxRoot);
  const record = createManualSandboxRecord(resolvedRoot, endpoints);
  let current = record;
  let child: ChildProcess | undefined = undefined;
  try {
    await persistManualSandboxRecord(current);
    const keystorePassword = randomBytes(24).toString('base64url');
    const certificatePath = path.join(resolvedRoot, 'greenmail-ca.pem');
    const keystorePath = path.join(resolvedRoot, 'greenmail.p12');
    const passwordPath = path.join(resolvedRoot, 'keystore-password');
    const argumentFile = path.join(resolvedRoot, 'java.args');
    current = {
      ...current,
      resources: {
        ...current.resources,
        paths: [
          argumentFile,
          certificatePath,
          keystorePath,
          passwordPath,
          path.join(resolvedRoot, 'greenmail.log'),
          path.join(resolvedRoot, 'DerivedData'),
          path.join(resolvedRoot, 'SourcePackages'),
        ],
      },
    };
    await persistManualSandboxRecord(current);
    await writeFile(passwordPath, keystorePassword, { mode: 0o600 });
    await generateCertificate({
      certificatePath,
      keystorePath,
      passwordPath,
      signal,
    });
    await writeJavaArguments(argumentFile, {
      artifact,
      ...endpoints,
      keystorePassword,
      keystorePath,
    });
    const started = await spawnGreenMail({
      argumentFile,
      logPath: path.join(resolvedRoot, 'greenmail.log'),
      signal,
    });
    const { child: startedChild, pid } = started;
    child = startedChild;
    current = {
      ...current,
      process: { commandMarker: argumentFile, pid },
    };
    await persistManualSandboxRecord(current);
    await waitForGreenMailReadiness(
      {
        ca: await readFile(certificatePath, 'utf8'),
        endpoints,
        signal,
      },
      startedChild,
    );
    await waitForGreenMailAPI(current, signal);
    await injectFixture(current, signal);
    const simulator = await createNamedMailTestSimulator(
      current.resources.simulatorIntent.name,
      signal,
    );
    current = {
      ...current,
      resources: { ...current.resources, simulator },
    };
    await persistManualSandboxRecord(current);
    await prepareMailTestSimulator(simulator, {
      certificatePath,
      host: '127.0.0.1',
      imapsPort: endpoints.imapsPort,
      runId: current.runId,
      scenario: 'core-mail-loop',
      signal,
      smtpsPort: endpoints.smtpsPort,
    });
    await launchManualMailTestApplication({
      root: resolvedRoot,
      signal,
      simulator,
    });
    child.unref();
    return evidence('started', 'running', current);
  } catch (error) {
    await cleanupFailedStart(current, child);
    throw error;
  }
}

export async function statusManualSandbox(
  signal?: AbortSignal,
  root?: string,
): Promise<ManualSandboxEvidence> {
  const sandboxRoot = await resolveManualSandboxRoot(root);
  if (!(await pathExists(sandboxRoot))) {
    return emptyEvidence('status');
  }
  const record = await readVerifiedManualSandboxRecord(sandboxRoot);
  const status = await sandboxProcessStatus(record, signal);
  return evidence('status', status, record);
}

export async function injectManualSandbox(
  signal?: AbortSignal,
  root?: string,
): Promise<ManualSandboxEvidence> {
  const sandboxRoot = await resolveManualSandboxRoot(root);
  const record = await requireRunningSandbox(sandboxRoot, signal);
  await injectFixture(record, signal);
  return evidence('injected', 'running', record);
}

export async function resetManualSandbox(
  signal?: AbortSignal,
  root?: string,
): Promise<ManualSandboxEvidence> {
  const sandboxRoot = await resolveManualSandboxRoot(root);
  if (!(await pathExists(sandboxRoot))) {
    throw new Error(
      'Manual Mail Sandbox is stopped. Run `pnpm mail:test sandbox start --scenario core-mail-loop`.',
    );
  }
  const record = await readVerifiedManualSandboxRecord(sandboxRoot);
  if (record.resources.simulator === null) {
    throw new Error(
      'Manual Mail Sandbox cannot reset because its owned simulator is missing.',
    );
  }
  if ((await sandboxProcessStatus(record, signal)) !== 'running') {
    throw new Error(
      'Manual Mail Sandbox is stale or unavailable. Run `pnpm mail:test sandbox stop`, then start it again.',
    );
  }
  await requestGreenMailAPI(record, {
    method: 'POST',
    resource: '/api/mail/purge',
    signal,
  });
  await injectFixture(record, signal);
  await resetManualMailTestApplication({
    root: record.root,
    signal,
    simulator: record.resources.simulator,
  });
  return evidence('reset', 'running', record);
}

export async function stopManualSandbox(
  root?: string,
): Promise<ManualSandboxEvidence> {
  const sandboxRoot = await resolveManualSandboxRoot(root);
  if (!(await pathExists(sandboxRoot))) {
    return emptyEvidence('stopped');
  }
  const record = await readVerifiedManualSandboxRecord(sandboxRoot);
  await stopRecordedProcess(record);
  await (record.resources.simulator === null
    ? deleteOwnedSimulatorIntent(record.resources.simulatorIntent)
    : deleteOwnedSimulator(record.resources.simulator));
  await rm(record.root, { recursive: true });
  return emptyEvidence('stopped');
}

export function createManualSandboxRecord(
  root: string,
  endpoints: MailEndpoints,
): ManualSandboxRecord {
  const runId = randomUUID();
  return {
    createdAt: new Date().toISOString(),
    kind: SANDBOX_KIND,
    process: null,
    resources: {
      endpoints,
      paths: [],
      simulator: null,
      simulatorIntent: {
        name: `${SIMULATOR_NAME_PREFIX} ${runId}`,
      },
    },
    root,
    runId,
    scenario: SANDBOX_SCENARIO,
    schemaVersion: 1,
    token: randomUUID(),
  };
}

export async function persistManualSandboxRecord(
  record: Readonly<ManualSandboxRecord>,
): Promise<void> {
  await writeFile(
    path.join(record.root, OWNERSHIP_FILE),
    `${JSON.stringify(record, null, 2)}\n`,
    { mode: 0o600 },
  );
}

export async function readVerifiedManualSandboxRecord(
  root: string,
): Promise<ManualSandboxRecord> {
  const resolvedRoot = await realpath(root);
  if (resolvedRoot !== root) {
    throw new Error(
      'Manual Mail Sandbox refused a redirected state directory.',
    );
  }
  const parsed: unknown = JSON.parse(
    await readFile(path.join(root, OWNERSHIP_FILE), 'utf8'),
  );
  if (!isManualSandboxRecord(parsed, root)) {
    throw new Error(
      'Manual Mail Sandbox ownership is uncertain; preserved all resources for manual inspection.',
    );
  }
  return parsed;
}

async function spawnGreenMail(options: {
  argumentFile: string;
  logPath: string;
  signal?: AbortSignal;
}): Promise<{ child: ChildProcess; pid: number }> {
  const log = await open(options.logPath, 'a', 0o600);
  try {
    const child = spawn(
      'mise',
      ['exec', '--', 'java', `@${options.argumentFile}`],
      {
        detached: true,
        signal: options.signal,
        stdio: ['ignore', log.fd, log.fd],
      },
    );
    child.on('error', (error: Error) => {
      process.stderr.write(
        `Manual Mail Sandbox GreenMail process reported an error: ${error.message}\n`,
      );
    });
    if (child.pid === undefined) {
      throw new Error('GreenMail did not expose a process identifier.');
    }
    return { child, pid: child.pid };
  } finally {
    await log.close();
  }
}

async function requireRunningSandbox(
  root: string,
  signal?: AbortSignal,
): Promise<ManualSandboxRecord> {
  if (!(await pathExists(root))) {
    throw new Error(
      'Manual Mail Sandbox is stopped. Run `pnpm mail:test sandbox start --scenario core-mail-loop`.',
    );
  }
  const record = await readVerifiedManualSandboxRecord(root);
  if ((await sandboxProcessStatus(record, signal)) !== 'running') {
    throw new Error(
      'Manual Mail Sandbox is stale or unavailable. Run `pnpm mail:test sandbox stop`, then start it again.',
    );
  }
  return record;
}

async function waitForGreenMailAPI(
  record: Readonly<ManualSandboxRecord>,
  signal?: AbortSignal,
): Promise<void> {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    signal?.throwIfAborted();
    try {
      await requestGreenMailAPI(record, {
        method: 'GET',
        resource: '/api/service/readiness',
        signal,
      });
      return;
    } catch {
      await new Promise<void>((resolve) => {
        setTimeout(resolve, 100);
      });
    }
  }
  throw new Error(
    'Manual Mail Sandbox control API did not become ready before the timeout.',
  );
}

async function sandboxProcessStatus(
  record: Readonly<ManualSandboxRecord>,
  signal?: AbortSignal,
): Promise<'running' | 'stale'> {
  if (record.process === null || !isProcessAlive(record.process.pid)) {
    return 'stale';
  }
  if (!(await processMatchesRecord(record))) {
    throw new Error(
      'Manual Mail Sandbox ownership is uncertain; the recorded PID no longer matches and no process was changed.',
    );
  }
  try {
    await requestGreenMailAPI(record, {
      method: 'GET',
      resource: '/api/service/readiness',
      signal,
    });
    return 'running';
  } catch {
    return 'stale';
  }
}

async function injectFixture(
  record: Readonly<ManualSandboxRecord>,
  signal?: AbortSignal,
): Promise<void> {
  const messages = await requestGreenMailAPI(record, {
    method: 'GET',
    resource: `/api/user/${encodeURIComponent(MAILBOX_EMAIL)}/messages/`,
    signal,
  });
  if (containsManualSandboxFixture(messages)) {
    return;
  }
  const certificate = await readFile(
    path.join(record.root, 'greenmail-ca.pem'),
    'utf8',
  );
  await sendSMTPSMessage(
    { ca: certificate, port: record.resources.endpoints.smtpsPort },
    { email: MAILBOX_EMAIL, password: MAILBOX_PASSWORD },
    syntheticMessage({
      body: FIXTURE_BODY,
      messageID: FIXTURE_MESSAGE_ID,
      subject: FIXTURE_SUBJECT,
    }),
  );
}

export function containsManualSandboxFixture(messages: unknown): boolean {
  if (!Array.isArray(messages)) {
    throw new TypeError(
      'Manual Mail Sandbox received an invalid message-list response.',
    );
  }
  return messages.some((message) => {
    if (!isRecord(message)) {
      return false;
    }
    const messageID = message['Message-ID'] ?? message.messageId;
    return (
      typeof messageID === 'string' &&
      messageID.replaceAll(/[<>]/gu, '') === FIXTURE_MESSAGE_ID
    );
  });
}

async function requestGreenMailAPI(
  record: Readonly<ManualSandboxRecord>,
  options: {
    method: 'GET' | 'POST';
    resource: string;
    signal?: AbortSignal;
  },
): Promise<unknown> {
  const response = await fetch(
    `http://127.0.0.1:${String(record.resources.endpoints.apiPort)}${options.resource}`,
    {
      method: options.method,
      signal:
        options.signal === undefined
          ? AbortSignal.timeout(5000)
          : AbortSignal.any([options.signal, AbortSignal.timeout(5000)]),
    },
  );
  if (!response.ok) {
    throw new Error(
      `Manual Mail Sandbox control request failed with HTTP ${String(response.status)}.`,
    );
  }
  return response.json() as Promise<unknown>;
}

async function stopRecordedProcess(
  record: Readonly<ManualSandboxRecord>,
): Promise<void> {
  const ownedProcess = record.process;
  if (ownedProcess === null || !isProcessAlive(ownedProcess.pid)) {
    return;
  }
  if (!(await processMatchesRecord(record))) {
    throw new Error(
      'Manual Mail Sandbox stop refused an unowned process; all resources were preserved.',
    );
  }
  process.kill(ownedProcess.pid, 'SIGTERM');
  if (await waitForProcessExit(ownedProcess.pid)) {
    return;
  }
  if (!(await processMatchesRecord(record))) {
    throw new Error(
      'Manual Mail Sandbox stop refused to force-stop a changed process; all remaining resources were preserved.',
    );
  }
  process.kill(ownedProcess.pid, 'SIGKILL');
  if (!(await waitForProcessExit(ownedProcess.pid))) {
    throw new Error(
      `Manual Mail Sandbox process ${String(ownedProcess.pid)} did not stop.`,
    );
  }
}

async function processMatchesRecord(
  record: Readonly<ManualSandboxRecord>,
): Promise<boolean> {
  if (record.process === null) {
    return false;
  }
  try {
    const result = await runCommand('ps', [
      '-p',
      String(record.process.pid),
      '-o',
      'command=',
    ]);
    return result.stdout.includes(record.process.commandMarker);
  } catch {
    return false;
  }
}

async function waitForProcessExit(pid: number): Promise<boolean> {
  const deadline = Date.now() + 2000;
  while (Date.now() < deadline) {
    if (!isProcessAlive(pid)) {
      return true;
    }
    await new Promise<void>((resolve) => {
      setTimeout(resolve, 50);
    });
  }
  return !isProcessAlive(pid);
}

async function cleanupFailedStart(
  record: Readonly<ManualSandboxRecord>,
  child?: ChildProcess,
): Promise<void> {
  const steps: Array<() => Promise<unknown>> = [
    async () => {
      if (child !== undefined) {
        await terminateProcess(child);
      }
    },
    async () =>
      record.resources.simulator === null
        ? deleteOwnedSimulatorIntent(record.resources.simulatorIntent)
        : deleteOwnedSimulator(record.resources.simulator),
    async () => rm(record.root, { recursive: true }),
  ];
  for (const step of steps) {
    try {
      await step();
    } catch (cleanupError) {
      process.stderr.write(
        `Manual Mail Sandbox cleanup failed; preserved owned state: ${String(cleanupError)}\n`,
      );
    }
  }
}

function evidence(
  action: SandboxAction,
  status: 'running' | 'stale',
  record: Readonly<ManualSandboxRecord>,
): ManualSandboxEvidence {
  return {
    action,
    endpoints: {
      imaps: {
        host: '127.0.0.1',
        port: record.resources.endpoints.imapsPort,
      },
      smtps: {
        host: '127.0.0.1',
        port: record.resources.endpoints.smtpsPort,
      },
    },
    kind: SANDBOX_KIND,
    processId: record.process?.pid,
    runId: record.runId,
    scenario: SANDBOX_SCENARIO,
    schemaVersion: 1,
    simulator: record.resources.simulator ?? undefined,
    status,
  };
}

function emptyEvidence(action: 'status' | 'stopped'): ManualSandboxEvidence {
  return {
    action,
    kind: SANDBOX_KIND,
    scenario: SANDBOX_SCENARIO,
    schemaVersion: 1,
    status: 'stopped',
  };
}

function isManualSandboxRecord(
  value: unknown,
  expectedRoot: string,
): value is ManualSandboxRecord {
  if (!isRecord(value) || !isRecord(value.resources)) {
    return false;
  }
  if (!hasManualSandboxIdentity(value, expectedRoot)) {
    return false;
  }
  return [
    isSandboxProcess(value.process, expectedRoot),
    isMailEndpoints(value.resources.endpoints),
    isOwnedPaths(value.resources.paths, expectedRoot),
    isSandboxSimulatorIntent(value.resources.simulatorIntent, value.runId),
    isSandboxSimulator(value.resources.simulator, value.runId),
  ].every(Boolean);
}

function hasManualSandboxIdentity(
  value: Record<string, unknown>,
  expectedRoot: string,
): value is Record<string, unknown> & { runId: string } {
  return [
    value.kind === SANDBOX_KIND,
    value.schemaVersion === 1,
    value.scenario === SANDBOX_SCENARIO,
    value.root === expectedRoot,
    typeof value.createdAt === 'string',
    isUUID(value.runId),
    isUUID(value.token),
  ].every(Boolean);
}

function isUUID(value: unknown): value is string {
  return typeof value === 'string' && UUID_PATTERN.test(value);
}

function isSandboxProcess(value: unknown, root: string): boolean {
  return (
    value === null ||
    (isRecord(value) &&
      value.commandMarker === path.join(root, 'java.args') &&
      typeof value.pid === 'number' &&
      Number.isSafeInteger(value.pid) &&
      value.pid > 0)
  );
}

function isMailEndpoints(value: unknown): value is MailEndpoints {
  if (!isRecord(value)) {
    return false;
  }
  const ports = [value.apiPort, value.imapsPort, value.smtpsPort];
  return (
    ports.every(
      (port) =>
        typeof port === 'number' &&
        Number.isSafeInteger(port) &&
        port > 0 &&
        port <= 65_535,
    ) && new Set(ports).size === ports.length
  );
}

function isOwnedPaths(value: unknown, root: string): value is string[] {
  return (
    Array.isArray(value) &&
    value.every(
      (ownedPath) =>
        typeof ownedPath === 'string' &&
        ownedPath.startsWith(`${root}${path.sep}`),
    )
  );
}

function isSandboxSimulatorIntent(value: unknown, runId: string): boolean {
  return isRecord(value) && value.name === `${SIMULATOR_NAME_PREFIX} ${runId}`;
}

function isSandboxSimulator(value: unknown, runId: string): boolean {
  return (
    value === null ||
    (isRecord(value) &&
      value.name === `${SIMULATOR_NAME_PREFIX} ${runId}` &&
      typeof value.runtime === 'string' &&
      value.runtime.length > 0 &&
      typeof value.udid === 'string' &&
      /^[0-9A-F-]{36}$/u.test(value.udid))
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

async function pathExists(value: string): Promise<boolean> {
  try {
    await stat(value);
    return true;
  } catch (error) {
    if (isRecord(error) && error.code === 'ENOENT') {
      return false;
    }
    throw error;
  }
}

async function resolveManualSandboxRoot(root?: string): Promise<string> {
  if (root !== undefined) {
    return root;
  }
  const defaultRoot = manualSandboxRoot();
  return (await pathExists(defaultRoot)) ? realpath(defaultRoot) : defaultRoot;
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}
