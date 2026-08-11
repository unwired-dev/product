import type { ChildProcess } from 'node:child_process';

import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';

import type {
  MailTestVisibleStep,
  MailTestVisibleStepOutcome,
} from './apple.ts';
import type { MessageContentFixture } from './message-content.ts';
import type { CleanupResult, OwnershipRecord } from './ownership.ts';
import type { IMAPMessageState } from './protocol.ts';
import type {
  CategorizationCategory,
  IncrementalArrivalFixture,
  IncrementalArrivalScenario,
} from './scenario.ts';

import {
  createMailTestSimulator,
  deleteOwnedSimulator,
  mailTestSimulatorIntent,
  prepareMailTestSimulator,
  runMailTestApplication,
} from './apple.ts';
import { resolveGreenMailArtifact } from './artifact.ts';
import { startMailTestCoordinator } from './coordination.ts';
import {
  encodeMessageContentExpectations,
  loadMessageContentFixtures,
} from './message-content.ts';
import {
  cleanupOwnedRun,
  createOwnershipRecord,
  persistOwnershipRecord,
  runDirectoryPrefix,
} from './ownership.ts';
import { allocateLoopbackPort, closeServer } from './ports.ts';
import { runCommand, terminateProcess, waitForExit } from './process.ts';
import {
  createIMAPMailboxes,
  inspectIMAPMessage,
  markAllIMAPMessagesSeen,
  readIMAPMessage,
  readUniqueIMAPMessageState,
  sendSMTPSMessage,
  setIMAPMessageFlags,
  snapshotIMAPMailbox,
  waitForMailServer,
  waitForSMTPServer,
} from './protocol.ts';
import {
  loadCategorizationFixtures,
  loadIncrementalArrivalScenario,
} from './scenario.ts';

export const MAILBOX_EMAIL = 'inbox@synthetic.invalid';
export const MAILBOX_PASSWORD = 'synthetic-test-password';
const READ_STATE_FIXTURE_ID = 'plain-text';
const SCENARIO_MAILBOXES = [
  'INBOX',
  'Archive',
  'Move Target',
  'Trash',
] as const;
const VISIBLE_STEPS = [
  'open',
  'mark-read',
  'archive',
  'move',
  'trash',
] as const satisfies readonly MailTestVisibleStep[];

interface VisibleStepEvidence {
  outcome: MailTestVisibleStepOutcome;
  serverState: 'verified';
}

type IMAPSnapshot = Awaited<ReturnType<typeof snapshotIMAPMailbox>>;
type IMAPSnapshotMessage = IMAPSnapshot['messages'][number];

export interface SmokeEvidence {
  artifact: {
    checksum: 'verified';
    version: string;
  };
  checks: {
    appBootstrap: true;
    imapRead: true;
    rawDelivery: true;
    smtpDelivery: true;
    visibleSeed: true;
  };
  cleanup: CleanupResult;
  endpoints: {
    imaps: { host: '127.0.0.1'; port: number; tls: string };
    smtps: { host: '127.0.0.1'; port: number; tls: string };
  };
  kind: 'mail-test-evidence';
  runId: string;
  scenario: 'core-mail-loop';
  schemaVersion: 2;
  status: 'passed';
  visibleClient: Record<MailTestVisibleStep, VisibleStepEvidence>;
}

export interface MessageContentEvidence {
  artifact: {
    checksum: 'verified';
    version: string;
  };
  checks: {
    attachmentState: true;
    fixtureBodies: true;
    inlineContentState: true;
    remoteContentBlocked: true;
    serverStatePreserved: true;
  };
  cleanup: CleanupResult;
  endpoints: {
    imaps: { host: '127.0.0.1'; port: number; tls: string };
    smtps: { host: '127.0.0.1'; port: number; tls: string };
  };
  fixtures: string[];
  kind: 'mail-test-evidence';
  runId: string;
  scenario: 'message-content';
  schemaVersion: 1;
  status: 'passed';
}

export interface CategorizationEvidence {
  artifact: {
    checksum: 'verified';
    version: string;
  };
  checks: {
    appBootstrap: true;
    productionCategorization: true;
    rawDelivery: true;
    visibleAssignments: true;
  };
  cleanup: CleanupResult;
  endpoints: {
    imaps: { host: '127.0.0.1'; port: number; tls: string };
    smtps: { host: '127.0.0.1'; port: number; tls: string };
  };
  fixtures: Array<{
    expectedCategory: CategorizationCategory | null;
    id: string;
    status: 'passed';
  }>;
  kind: 'mail-test-evidence';
  runId: string;
  scenario: 'categorization';
  schemaVersion: 1;
  status: 'passed';
}

export interface IncrementalArrivalEvidence {
  artifact: {
    checksum: 'verified';
    version: string;
  };
  checks: {
    initialSynchronization: true;
    injection: true;
    preservedInitialState: true;
    providerObservation: true;
    reconciliation: true;
    repeatedRefresh: true;
    visiblePresentation: true;
  };
  cleanup: CleanupResult;
  endpoints: SmokeEvidence['endpoints'];
  fixtures: Array<{
    id: string;
    stage: 'incremental' | 'initial';
    status: 'passed';
  }>;
  kind: 'mail-test-evidence';
  provider: 'greenmail';
  providerDifferences: IncrementalArrivalScenario['providerDifferences'];
  runId: string;
  scenario: 'incremental-arrival';
  schemaVersion: 1;
  status: 'passed';
}

export class MessageContentFixtureError extends Error {
  public override name = 'MessageContentFixtureError';
  public readonly fixtureId: string;

  public constructor(fixtureId: string, message: string) {
    super(`[fixture: ${fixtureId}] ${message}`);
    this.fixtureId = fixtureId;
  }
}

export interface MailEndpoints {
  apiPort: number;
  imapsPort: number;
  smtpsPort: number;
}

interface MailTestRunState {
  child?: ChildProcess;
  cleanup?: CleanupResult;
  diagnostics: Buffer[];
  diagnosticSecrets: string[];
  ownership: OwnershipRecord;
}

interface OwnedMailTestContext {
  ca: string;
  endpoints: MailEndpoints;
  root: string;
  signal?: AbortSignal;
  state: MailTestRunState;
}

interface OwnedMailTestResult<T> {
  cleanup: CleanupResult;
  context: OwnedMailTestContext;
  value: T;
}

interface CategorizationRunEvidence {
  fixtures: CategorizationEvidence['fixtures'];
  imapTLS: string;
  smtpTLS: string;
}

interface IncrementalArrivalRunEvidence {
  imapTLS: string;
  scenario: IncrementalArrivalScenario;
  smtpTLS: string;
}

interface MailClientCoordination {
  close: () => Promise<void>;
  environment: Readonly<Record<string, string>>;
  verifyCompleted: () => Promise<void>;
}

export async function runCoreMailLoopSmoke(
  signal?: AbortSignal,
): Promise<SmokeEvidence> {
  const result = await runOwnedMailTest(signal, async (context) => {
    const mail = await exerciseMailLoop(
      context.endpoints,
      context.ca,
      context.state.ownership.runId,
    );
    const visibleClient = await exerciseVisibleStepsClient({
      certificatePath: path.join(context.root, 'greenmail-ca.pem'),
      endpoints: context.endpoints,
      messages: mail.visibleMessages,
      root: context.root,
      signal,
      state: context.state,
    });
    return { ...mail, visibleClient };
  });
  return {
    artifact: { checksum: 'verified', version: '2.1.12' },
    checks: {
      appBootstrap: true,
      imapRead: true,
      rawDelivery: true,
      smtpDelivery: true,
      visibleSeed: true,
    },
    cleanup: result.cleanup,
    endpoints: evidenceEndpoints(result.context.endpoints, result.value),
    kind: 'mail-test-evidence',
    runId: result.context.state.ownership.runId,
    scenario: 'core-mail-loop',
    schemaVersion: 2,
    status: 'passed',
    visibleClient: result.value.visibleClient,
  };
}

export async function runMessageContentScenario(
  signal?: AbortSignal,
): Promise<MessageContentEvidence> {
  const result = await runOwnedMailTest(signal, exerciseMessageContent);
  return {
    artifact: { checksum: 'verified', version: '2.1.12' },
    checks: {
      attachmentState: true,
      fixtureBodies: true,
      inlineContentState: true,
      remoteContentBlocked: true,
      serverStatePreserved: true,
    },
    cleanup: result.cleanup,
    endpoints: evidenceEndpoints(result.context.endpoints, result.value),
    fixtures: result.value.fixtureIds,
    kind: 'mail-test-evidence',
    runId: result.context.state.ownership.runId,
    scenario: 'message-content',
    schemaVersion: 1,
    status: 'passed',
  };
}

export async function runCategorizationScenario(
  signal?: AbortSignal,
): Promise<CategorizationEvidence> {
  const result = await runOwnedMailTest(signal, async (context) => {
    const categorization = await exerciseCategorization(
      context.endpoints,
      context.ca,
      context.state.ownership.runId,
    );
    await exerciseVisibleMailClient({
      certificatePath: path.join(context.root, 'greenmail-ca.pem'),
      endpoints: context.endpoints,
      root: context.root,
      scenario: 'categorization',
      signal,
      state: context.state,
      testName: 'testCategorizedFixturesAppearInVisibleMailbox',
    });
    return categorization;
  });
  return {
    artifact: { checksum: 'verified', version: '2.1.12' },
    checks: {
      appBootstrap: true,
      productionCategorization: true,
      rawDelivery: true,
      visibleAssignments: true,
    },
    cleanup: result.cleanup,
    endpoints: evidenceEndpoints(result.context.endpoints, result.value),
    fixtures: result.value.fixtures,
    kind: 'mail-test-evidence',
    runId: result.context.state.ownership.runId,
    scenario: 'categorization',
    schemaVersion: 1,
    status: 'passed',
  };
}

export async function runIncrementalArrivalScenario(
  signal?: AbortSignal,
): Promise<IncrementalArrivalEvidence> {
  const completed = await runOwnedMailTest(signal, async (context) => {
    const result = await exerciseIncrementalArrivalInitialState(
      context.endpoints,
      context.ca,
      context.state.ownership.runId,
    );
    const coordination = await coordinateIncrementalArrival({
      ca: context.ca,
      endpoints: context.endpoints,
      result,
      runId: context.state.ownership.runId,
      signal,
    });
    try {
      await exerciseVisibleMailClient({
        additionalEnvironment: coordination.environment,
        certificatePath: path.join(context.root, 'greenmail-ca.pem'),
        endpoints: context.endpoints,
        root: context.root,
        scenario: 'incremental-arrival',
        signal,
        state: context.state,
        testName: 'testIncrementalArrivalRefreshesExistingMailbox',
      });
      await coordination.verifyCompleted();
    } finally {
      await coordination.close();
    }
    return result;
  });
  return {
    artifact: { checksum: 'verified', version: '2.1.12' },
    checks: {
      initialSynchronization: true,
      injection: true,
      preservedInitialState: true,
      providerObservation: true,
      reconciliation: true,
      repeatedRefresh: true,
      visiblePresentation: true,
    },
    cleanup: completed.cleanup,
    endpoints: evidenceEndpoints(completed.context.endpoints, completed.value),
    fixtures: completed.value.scenario.fixtures.map(({ id, stage }) => ({
      id,
      stage,
      status: 'passed',
    })),
    kind: 'mail-test-evidence',
    provider: 'greenmail',
    providerDifferences: completed.value.scenario.providerDifferences,
    runId: completed.context.state.ownership.runId,
    scenario: 'incremental-arrival',
    schemaVersion: 1,
    status: 'passed',
  };
}

async function runOwnedMailTest<T>(
  signal: AbortSignal | undefined,
  exercise: (context: OwnedMailTestContext) => Promise<T>,
): Promise<OwnedMailTestResult<T>> {
  signal?.throwIfAborted();
  const artifact = await resolveGreenMailArtifact({ signal });
  await verifyJavaToolchain(signal);
  const temporaryBase = await realpath(tmpdir());
  const root = await mkdtemp(path.join(temporaryBase, runDirectoryPrefix()));
  const ownership = await createSmokeOwnership(root);
  const state: MailTestRunState = {
    diagnostics: [],
    diagnosticSecrets: [],
    ownership,
  };
  const onAbort = (): void => {
    state.child?.kill('SIGTERM');
  };
  signal?.addEventListener('abort', onAbort, { once: true });

  try {
    const endpoints = await allocateMailEndpoints();
    const ca = await prepareGreenMailRun({
      artifact,
      endpoints,
      root,
      signal,
      state,
    });
    await startGreenMail({ ca, endpoints, root, signal, state });
    signal?.throwIfAborted();
    const context = { ca, endpoints, root, signal, state };
    const value = await exercise(context);
    state.cleanup = await cleanupOwnedRun(state.ownership, state.child);
    return { cleanup: state.cleanup, context, value };
  } catch (error) {
    const diagnosticText = redactDiagnostics(
      Buffer.concat(state.diagnostics).toString('utf8'),
      state.diagnosticSecrets,
    );
    if (diagnosticText.length > 0) {
      process.stderr.write(`${diagnosticText}\n`);
    }
    throw redactedError(error, state.diagnosticSecrets);
  } finally {
    signal?.removeEventListener('abort', onAbort);
    await cleanupFailedSmokeRun(state);
  }
}

async function exerciseVisibleMailClient(options: {
  additionalEnvironment?: Readonly<Record<string, string>>;
  certificatePath: string;
  endpoints: Readonly<MailEndpoints>;
  root: string;
  scenario:
    | 'categorization'
    | 'core-mail-loop'
    | 'incremental-arrival'
    | 'message-content';
  signal?: AbortSignal;
  state: MailTestRunState;
  testName: string;
}): Promise<void> {
  const simulator = await prepareOwnedMailTestSimulator({
    additionalEnvironment: options.additionalEnvironment,
    certificatePath: options.certificatePath,
    endpoints: options.endpoints,
    scenario: options.scenario,
    signal: options.signal,
    state: options.state,
  });
  await runMailTestApplication({
    root: options.root,
    signal: options.signal,
    simulator,
    testName: options.testName,
  });
}

async function exerciseVisibleStepsClient(options: {
  certificatePath: string;
  endpoints: Readonly<MailEndpoints>;
  messages: Readonly<Record<MailTestVisibleStep, string>>;
  root: string;
  signal?: AbortSignal;
  state: MailTestRunState;
}): Promise<Record<MailTestVisibleStep, VisibleStepEvidence>> {
  const simulator = await prepareOwnedMailTestSimulator({
    certificatePath: options.certificatePath,
    endpoints: options.endpoints,
    scenario: 'core-mail-loop',
    signal: options.signal,
    state: options.state,
  });
  const ca = await readFile(options.certificatePath, 'utf8');
  const runStep = async (
    step: MailTestVisibleStep,
  ): Promise<VisibleStepEvidence> => {
    const baseline = await inspectIMAPMessage(
      { ca, port: options.endpoints.imapsPort },
      { email: MAILBOX_EMAIL, password: MAILBOX_PASSWORD },
      { mailboxes: SCENARIO_MAILBOXES, messageID: options.messages[step] },
    );
    const [baselineLocation] = baseline.locations;
    if (
      baseline.locations.length !== 1 ||
      baselineLocation?.mailbox !== 'INBOX'
    ) {
      throw new Error(
        `Visible step ${step} did not begin with exactly one message in INBOX.`,
      );
    }
    const outcome = await runMailTestApplication({
      root: options.root,
      signal: options.signal,
      simulator,
      step,
    });
    await verifyVisibleStepServerState({
      ca,
      baselineFlags: baselineLocation.flags,
      endpoints: options.endpoints,
      messageID: options.messages[step],
      outcome,
      signal: options.signal,
      step,
    });
    return { outcome, serverState: 'verified' };
  };
  const open = await runStep('open');
  const markRead = await runStep('mark-read');
  const archive = await runStep('archive');
  const move = await runStep('move');
  const trash = await runStep('trash');
  return { archive, 'mark-read': markRead, move, open, trash };
}

async function prepareOwnedMailTestSimulator(options: {
  additionalEnvironment?: Readonly<Record<string, string>>;
  certificatePath: string;
  endpoints: Readonly<MailEndpoints>;
  scenario: Parameters<typeof prepareMailTestSimulator>[1]['scenario'];
  signal?: AbortSignal;
  state: MailTestRunState;
}): Promise<Parameters<typeof runMailTestApplication>[0]['simulator']> {
  const simulatorIntent = mailTestSimulatorIntent(
    options.state.ownership.runId,
  );
  options.state.ownership = {
    ...options.state.ownership,
    resources: {
      ...options.state.ownership.resources,
      simulatorIntents: [simulatorIntent],
    },
  };
  await persistOwnershipRecord(options.state.ownership);
  const simulator = await createMailTestSimulator(
    options.state.ownership.runId,
    options.signal,
  );
  options.state.ownership = {
    ...options.state.ownership,
    resources: {
      ...options.state.ownership.resources,
      simulatorIntents: [],
      simulators: [simulator],
    },
  };
  try {
    await persistOwnershipRecord(options.state.ownership);
  } catch (error) {
    await deleteOwnedSimulator(simulator);
    throw error;
  }
  await prepareMailTestSimulator(simulator, {
    additionalEnvironment: options.additionalEnvironment,
    certificatePath: options.certificatePath,
    host: '127.0.0.1',
    imapsPort: options.endpoints.imapsPort,
    runId: options.state.ownership.runId,
    scenario: 'core-mail-loop',
    signal: options.signal,
    smtpsPort: options.endpoints.smtpsPort,
  });
  return simulator;
}

async function verifyVisibleStepServerState(options: {
  baselineFlags: readonly string[];
  ca: string;
  endpoints: Readonly<MailEndpoints>;
  messageID: string;
  outcome: MailTestVisibleStepOutcome;
  signal?: AbortSignal;
  step: MailTestVisibleStep;
}): Promise<void> {
  const expectedMailbox =
    options.outcome === 'unavailable'
      ? 'INBOX'
      : targetMailboxForStep(options.step);
  const expectsSeen =
    options.step === 'mark-read' ? options.outcome === 'performed' : undefined;
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    options.signal?.throwIfAborted();
    const inspection = await inspectIMAPMessage(
      { ca: options.ca, port: options.endpoints.imapsPort },
      { email: MAILBOX_EMAIL, password: MAILBOX_PASSWORD },
      { mailboxes: SCENARIO_MAILBOXES, messageID: options.messageID },
    );
    if (
      isExpectedVisibleStepInspection({
        baselineFlags: options.baselineFlags,
        expectedMailbox,
        expectsSeen,
        inspection,
        outcome: options.outcome,
      })
    ) {
      return;
    }
    await new Promise<void>((resolve) => {
      setTimeout(resolve, 250);
    });
  }
  throw new Error(
    `Server assertion failed after visible step ${options.step}: expected one message in ${expectedMailbox} with the required read state.`,
  );
}

function isExpectedVisibleStepInspection(options: {
  baselineFlags: readonly string[];
  expectedMailbox: string;
  expectsSeen: boolean | undefined;
  inspection: Awaited<ReturnType<typeof inspectIMAPMessage>>;
  outcome: MailTestVisibleStepOutcome;
}): boolean {
  const [location] = options.inspection.locations;
  if (
    options.inspection.locations.length !== 1 ||
    location?.mailbox !== options.expectedMailbox
  ) {
    return false;
  }
  if (
    options.outcome === 'unavailable' &&
    location.flags.join('\0') !== options.baselineFlags.join('\0')
  ) {
    return false;
  }
  return (
    options.expectsSeen === undefined ||
    location.flags.includes(String.raw`\Seen`) === options.expectsSeen
  );
}

function targetMailboxForStep(step: MailTestVisibleStep): string {
  switch (step) {
    case 'archive': {
      return 'Archive';
    }
    case 'move': {
      return 'Move Target';
    }
    case 'trash': {
      return 'Trash';
    }
    case 'mark-read':
    case 'open': {
      return 'INBOX';
    }
    default: {
      throw new Error(`Unknown visible mail test step: ${String(step)}.`);
    }
  }
}

async function cleanupFailedSmokeRun(state: MailTestRunState): Promise<void> {
  if (state.cleanup !== undefined) {
    return;
  }
  try {
    await cleanupOwnedRun(state.ownership, state.child);
  } catch (cleanupError) {
    process.stderr.write(`Mail test cleanup failed: ${String(cleanupError)}\n`);
  }
}

async function createSmokeOwnership(root: string): Promise<OwnershipRecord> {
  try {
    return await createOwnershipRecord(root);
  } catch (error) {
    await rm(root, { force: true, recursive: true });
    throw error;
  }
}

export async function allocateMailEndpoints(): Promise<MailEndpoints> {
  const imapsPort = await allocateLoopbackPort();
  let smtpsPort = await allocateLoopbackPort();
  while (smtpsPort === imapsPort) {
    smtpsPort = await allocateLoopbackPort();
  }
  let apiPort = await allocateLoopbackPort();
  while (apiPort === imapsPort || apiPort === smtpsPort) {
    apiPort = await allocateLoopbackPort();
  }
  return { apiPort, imapsPort, smtpsPort };
}

async function prepareGreenMailRun(options: {
  artifact: string;
  endpoints: Readonly<MailEndpoints>;
  root: string;
  signal?: AbortSignal;
  state: MailTestRunState;
}): Promise<string> {
  const keystorePassword = randomBytes(24).toString('base64url');
  options.state.diagnosticSecrets.push(keystorePassword);
  const keystorePath = path.join(options.root, 'greenmail.p12');
  const certificatePath = path.join(options.root, 'greenmail-ca.pem');
  const passwordPath = path.join(options.root, 'keystore-password');
  const argumentFile = path.join(options.root, 'java.args');
  options.state.ownership = {
    ...options.state.ownership,
    resources: {
      paths: [argumentFile, certificatePath, keystorePath, passwordPath],
      ports: [
        options.endpoints.apiPort,
        options.endpoints.imapsPort,
        options.endpoints.smtpsPort,
      ],
    },
  };
  await persistOwnershipRecord(options.state.ownership);
  await writeFile(passwordPath, keystorePassword, { mode: 0o600 });
  await generateCertificate({
    certificatePath,
    keystorePath,
    passwordPath,
    signal: options.signal,
  });
  await writeJavaArguments(argumentFile, {
    artifact: options.artifact,
    ...options.endpoints,
    keystorePassword,
    keystorePath,
  });
  return readFile(certificatePath, 'utf8');
}

async function startGreenMail(options: {
  ca: string;
  endpoints: Readonly<MailEndpoints>;
  root: string;
  signal?: AbortSignal;
  state: MailTestRunState;
}): Promise<void> {
  const argumentFile = path.join(options.root, 'java.args');
  const child = spawn('mise', ['exec', '--', 'java', `@${argumentFile}`], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  options.state.child = child;
  await persistGreenMailProcess(options.state, child, argumentFile);
  captureGreenMailDiagnostics(options.state, child);
  await waitForGreenMailReadiness(options, child);
}

async function persistGreenMailProcess(
  state: MailTestRunState,
  child: ChildProcess,
  argumentFile: string,
): Promise<void> {
  if (child.pid === undefined) {
    throw new Error('GreenMail did not expose a process identifier.');
  }
  state.ownership = {
    ...state.ownership,
    process: { commandMarker: argumentFile, pid: child.pid },
  };
  try {
    await persistOwnershipRecord(state.ownership);
  } catch (error) {
    await terminateProcess(child);
    throw error;
  }
}

function captureGreenMailDiagnostics(
  state: MailTestRunState,
  child: ChildProcess,
): void {
  if (child.stdout === null || child.stderr === null) {
    throw new Error('GreenMail diagnostics were not captured.');
  }
  child.stdout.on('data', (chunk: Buffer) => {
    appendBounded(state.diagnostics, chunk);
  });
  child.stderr.on('data', (chunk: Buffer) => {
    appendBounded(state.diagnostics, chunk);
  });
}

export async function waitForGreenMailReadiness(
  options: {
    ca: string;
    endpoints: Readonly<MailEndpoints>;
    signal?: AbortSignal;
  },
  child: ChildProcess,
): Promise<void> {
  await Promise.race([
    Promise.all([
      waitForMailServer(
        { ca: options.ca, port: options.endpoints.imapsPort },
        options.signal,
      ),
      waitForSMTPServer(
        { ca: options.ca, port: options.endpoints.smtpsPort },
        options.signal,
      ),
    ]),
    waitForExit(child).then((exitCode) => {
      throw new Error(
        `GreenMail exited before readiness with status ${String(exitCode)}.`,
      );
    }),
  ]);
}

async function exerciseMailLoop(
  endpoints: Readonly<MailEndpoints>,
  ca: string,
  runId: string,
): Promise<{
  imapTLS: string;
  smtpTLS: string;
  visibleMessages: Record<MailTestVisibleStep, string>;
}> {
  const imaps = { ca, port: endpoints.imapsPort };
  const smtps = { ca, port: endpoints.smtpsPort };
  const seedID = `${runId}.seed@synthetic.invalid`;
  const deliveryID = `${runId}.delivery@synthetic.invalid`;
  const seedBody = `synthetic-seed-${runId}`;
  const deliveryBody = `synthetic-delivery-${runId}`;
  const credentials = { email: MAILBOX_EMAIL, password: MAILBOX_PASSWORD };
  await createIMAPMailboxes(imaps, credentials, SCENARIO_MAILBOXES.slice(1));
  const smtpTLS = await sendSMTPSMessage(
    smtps,
    credentials,
    syntheticMessage(seedID, 'Synthetic seed', seedBody),
  );
  const seed = await readIMAPMessage(imaps, credentials, seedID);
  if (!seed.raw.includes(seedBody)) {
    throw new Error('IMAP did not return the expected synthetic seed message.');
  }
  await sendSMTPSMessage(
    smtps,
    credentials,
    syntheticMessage(deliveryID, 'Synthetic SMTP delivery', deliveryBody),
  );
  const delivery = await readIMAPMessage(imaps, credentials, deliveryID);
  if (!delivery.raw.includes(deliveryBody)) {
    throw new Error('The delivered message body did not match the submission.');
  }
  if (!delivery.raw.includes(`Message-ID: <${deliveryID}>`)) {
    throw new Error('The delivered Message-ID did not match the submission.');
  }
  const visibleMessages: Record<MailTestVisibleStep, string> = {
    archive: `${runId}.archive@synthetic.invalid`,
    'mark-read': `${runId}.mark-read@synthetic.invalid`,
    move: `${runId}.move@synthetic.invalid`,
    open: `${runId}.open@synthetic.invalid`,
    trash: `${runId}.trash@synthetic.invalid`,
  };
  const subjects: Record<MailTestVisibleStep, string> = {
    archive: 'Mail Test Archive',
    'mark-read': 'Mail Test Mark Read',
    move: 'Mail Test Move',
    open: 'Mail Test Open',
    trash: 'Mail Test Trash',
  };
  for (const step of VISIBLE_STEPS) {
    await sendSMTPSMessage(
      smtps,
      credentials,
      syntheticMessage(
        visibleMessages[step],
        subjects[step],
        `synthetic-visible-${step}-${runId}`,
      ),
    );
  }
  return { imapTLS: seed.tlsVersion, smtpTLS, visibleMessages };
}

async function exerciseMessageContent(context: OwnedMailTestContext): Promise<{
  fixtureIds: string[];
  imapTLS: string;
  smtpTLS: string;
}> {
  const remoteContentPort = await registerRemoteContentPort(context);
  const beacon = await startRemoteContentBeacon(remoteContentPort);
  try {
    const fixtures = await loadMessageContentFixtures(
      `https://127.0.0.1:${String(remoteContentPort)}/remote-content.png`,
    );
    context.state.diagnosticSecrets.push(
      ...fixtures.map((fixture) => fixture.expectedBody),
    );
    const credentials = {
      email: MAILBOX_EMAIL,
      password: MAILBOX_PASSWORD,
    };
    const imaps = { ca: context.ca, port: context.endpoints.imapsPort };
    const smtps = { ca: context.ca, port: context.endpoints.smtpsPort };
    const { imapTLS, smtpTLS } = await deliverMessageContentCorpus(fixtures, {
      credentials,
      imaps,
      smtps,
    });
    const readStateFixture = fixtures.find(
      (fixture) => fixture.id === READ_STATE_FIXTURE_ID,
    );
    if (readStateFixture === undefined) {
      throw new MessageContentFixtureError(
        READ_STATE_FIXTURE_ID,
        'The read-state fixture is missing.',
      );
    }
    await markAllIMAPMessagesSeen(imaps, credentials, {
      exceptMessageIds: [readStateFixture.messageId],
    });
    const before = await snapshotIMAPMailbox(imaps, credentials);
    assertFixtureIdentities(
      fixtures.map(({ id, messageId }) => ({ id, messageId })),
      before.messages.map(({ messageId }) => messageId),
    );
    await exerciseVisibleMessageContent(context, fixtures);
    const after = await snapshotIMAPMailbox(imaps, credentials);
    verifyMessageContentOutcome(fixtures, {
      after,
      before,
      remoteConnectionCount: beacon.connectionCount(),
    });
    return {
      fixtureIds: fixtures.map((fixture) => fixture.id),
      imapTLS,
      smtpTLS,
    };
  } finally {
    await beacon.close();
  }
}

async function registerRemoteContentPort(
  context: OwnedMailTestContext,
): Promise<number> {
  const remoteContentPort = await allocateLoopbackPort();
  context.state.ownership = {
    ...context.state.ownership,
    resources: {
      ...context.state.ownership.resources,
      ports: [...context.state.ownership.resources.ports, remoteContentPort],
    },
  };
  await persistOwnershipRecord(context.state.ownership);
  return remoteContentPort;
}

async function deliverMessageContentCorpus(
  fixtures: readonly MessageContentFixture[],
  options: {
    credentials: { email: string; password: string };
    imaps: { ca: string; port: number };
    smtps: { ca: string; port: number };
  },
): Promise<{ imapTLS: string; smtpTLS: string }> {
  let imapTLS = 'unknown';
  let smtpTLS = 'unknown';
  for (const fixture of fixtures) {
    ({ imapTLS, smtpTLS } = await deliverMessageContentFixture(
      fixture,
      options,
    ));
  }
  return { imapTLS, smtpTLS };
}

async function exerciseVisibleMessageContent(
  context: OwnedMailTestContext,
  fixtures: readonly MessageContentFixture[],
): Promise<void> {
  try {
    await exerciseVisibleMailClient({
      additionalEnvironment: {
        MAIL_TEST_SCENARIO_FIXTURES: encodeMessageContentExpectations(fixtures),
      },
      certificatePath: path.join(context.root, 'greenmail-ca.pem'),
      endpoints: context.endpoints,
      root: context.root,
      scenario: 'message-content',
      signal: context.signal,
      state: context.state,
      testName: 'testMessageContentCorpusInVisibleMailbox',
    });
  } catch (error) {
    throw visibleMessageContentError(error);
  }
}

export function visibleMessageContentError(
  error: unknown,
): MessageContentFixtureError {
  if (error instanceof MessageContentFixtureError) {
    return error;
  }
  const message = unknownErrorMessage(error);
  const fixtureMatch = /\[fixture: (?<fixtureId>[a-z0-9-]+)\] /u.exec(message);
  const fixtureId = fixtureMatch?.groups?.fixtureId;
  if (fixtureMatch === null || fixtureId === undefined) {
    return new MessageContentFixtureError('visible-client', message);
  }
  return new MessageContentFixtureError(
    fixtureId,
    message.replace(fixtureMatch[0], ''),
  );
}

function unknownErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function verifyMessageContentOutcome(
  fixtures: readonly MessageContentFixture[],
  outcome: {
    after: Awaited<ReturnType<typeof snapshotIMAPMailbox>>;
    before: Awaited<ReturnType<typeof snapshotIMAPMailbox>>;
    remoteConnectionCount: number;
  },
): void {
  assertPreservedMailboxState(fixtures, outcome);
  if (outcome.remoteConnectionCount !== 0) {
    throw new MessageContentFixtureError(
      'remote-content',
      'The visible client connected to the prohibited remote-content endpoint.',
    );
  }
}

function evidenceEndpoints(
  endpoints: Readonly<MailEndpoints>,
  tls: { imapTLS: string; smtpTLS: string },
): {
  imaps: { host: '127.0.0.1'; port: number; tls: string };
  smtps: { host: '127.0.0.1'; port: number; tls: string };
} {
  return {
    imaps: {
      host: '127.0.0.1',
      port: endpoints.imapsPort,
      tls: tls.imapTLS,
    },
    smtps: {
      host: '127.0.0.1',
      port: endpoints.smtpsPort,
      tls: tls.smtpTLS,
    },
  };
}

async function withMessageContentFixture<T>(
  fixtureId: string,
  operation: () => Promise<T>,
): Promise<T> {
  try {
    return await operation();
  } catch (error) {
    if (error instanceof MessageContentFixtureError) {
      throw error;
    }
    throw new MessageContentFixtureError(
      fixtureId,
      error instanceof Error ? error.message : String(error),
    );
  }
}

async function deliverMessageContentFixture(
  fixture: Readonly<MessageContentFixture>,
  options: {
    credentials: { email: string; password: string };
    imaps: { ca: string; port: number };
    smtps: { ca: string; port: number };
  },
): Promise<{ imapTLS: string; smtpTLS: string }> {
  return withMessageContentFixture(fixture.id, async () => {
    const smtpTLS = await sendSMTPSMessage(
      options.smtps,
      options.credentials,
      fixture.rawMessage,
    );
    const delivered = await readIMAPMessage(
      options.imaps,
      options.credentials,
      fixture.messageId,
    );
    if (
      !delivered.raw.includes(fixture.expectedBody) ||
      !delivered.raw.includes(`Message-ID: <${fixture.messageId}>`)
    ) {
      throw new Error('The synthetic raw message changed during delivery.');
    }
    return { imapTLS: delivered.tlsVersion, smtpTLS };
  });
}

function assertFixtureIdentities(
  fixtures: ReadonlyArray<{ id: string; messageId: string }>,
  actualMessageIds: readonly string[],
): void {
  for (const fixture of fixtures) {
    if (!actualMessageIds.includes(fixture.messageId)) {
      throw new MessageContentFixtureError(
        fixture.id,
        'The server snapshot did not preserve the fixture Message-ID.',
      );
    }
  }
  if (actualMessageIds.length !== fixtures.length) {
    throw new MessageContentFixtureError(
      'server-state',
      'The isolated mailbox contained an unexpected message identity.',
    );
  }
}

function assertPreservedMailboxState(
  fixtures: ReadonlyArray<{ id: string; messageId: string }>,
  snapshots: {
    after: Awaited<ReturnType<typeof snapshotIMAPMailbox>>;
    before: Awaited<ReturnType<typeof snapshotIMAPMailbox>>;
  },
): void {
  const { after, before } = snapshots;
  if (JSON.stringify(before.mailboxes) !== JSON.stringify(after.mailboxes)) {
    throw new MessageContentFixtureError(
      'server-state',
      'Visible presentation changed the server mailbox set.',
    );
  }
  for (const fixture of fixtures) {
    const beforeMessage = requireSnapshotMessage(
      before.messages.find(
        (message) => message.messageId === fixture.messageId,
      ),
      fixture.id,
    );
    const afterMessage = requireSnapshotMessage(
      after.messages.find((message) => message.messageId === fixture.messageId),
      fixture.id,
    );
    assertPreservedMessage(fixture, { afterMessage, beforeMessage });
  }
  if (before.messages.length !== after.messages.length) {
    throw new MessageContentFixtureError(
      'server-state',
      'Visible presentation changed the server message count.',
    );
  }
}

function requireSnapshotMessage(
  message: IMAPSnapshotMessage | undefined,
  fixtureId: string,
): IMAPSnapshotMessage {
  if (message === undefined) {
    throw new MessageContentFixtureError(
      fixtureId,
      'Visible presentation changed the server message identity.',
    );
  }
  return message;
}

function assertPreservedMessage(
  fixture: Readonly<{ id: string; messageId: string }>,
  state: {
    afterMessage: IMAPSnapshotMessage;
    beforeMessage: IMAPSnapshotMessage;
  },
): void {
  if (
    JSON.stringify(state.beforeMessage) !== JSON.stringify(state.afterMessage)
  ) {
    throw new MessageContentFixtureError(
      fixture.id,
      'Visible presentation changed the server UID, flags, or Message-ID.',
    );
  }
}

async function startRemoteContentBeacon(
  port: number,
): Promise<{ close: () => Promise<void>; connectionCount: () => number }> {
  let connections = 0;
  const server = createServer((socket) => {
    connections += 1;
    socket.destroy();
  });
  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error): void => {
      server.off('listening', onListening);
      reject(error);
    };
    const onListening = (): void => {
      server.off('error', onError);
      resolve();
    };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(port, '127.0.0.1');
  });
  server.unref();
  return {
    close: async () => {
      if (!server.listening) {
        return;
      }
      await closeServer(server);
    },
    connectionCount: () => connections,
  };
}

async function exerciseCategorization(
  endpoints: Readonly<MailEndpoints>,
  ca: string,
  runId: string,
): Promise<CategorizationRunEvidence> {
  const imaps = { ca, port: endpoints.imapsPort };
  const smtps = { ca, port: endpoints.smtpsPort };
  const credentials = { email: MAILBOX_EMAIL, password: MAILBOX_PASSWORD };
  const fixtures = await loadCategorizationFixtures(runId, new Date());
  let imapTLS = 'unknown';
  let smtpTLS = 'unknown';
  for (const fixture of fixtures) {
    smtpTLS = await sendSMTPSMessage(smtps, credentials, fixture.rawMessage);
    const delivered = await readIMAPMessage(
      imaps,
      credentials,
      fixture.messageId,
    );
    imapTLS = delivered.tlsVersion;
    if (!delivered.raw.includes(`Message-ID: <${fixture.messageId}>`)) {
      throw new Error(
        `Categorization fixture ${fixture.id} was not independently visible through IMAP.`,
      );
    }
  }
  return {
    fixtures: fixtures.map(({ expectedCategory, id }) => ({
      expectedCategory,
      id,
      status: 'passed',
    })),
    imapTLS,
    smtpTLS,
  };
}

async function exerciseIncrementalArrivalInitialState(
  endpoints: Readonly<MailEndpoints>,
  ca: string,
  runId: string,
): Promise<IncrementalArrivalRunEvidence> {
  const scenario = await loadIncrementalArrivalScenario(runId, new Date());
  const initial = scenario.fixtures.find(
    (fixture) => fixture.stage === 'initial',
  );
  if (initial === undefined) {
    throw new Error(
      'Incremental-arrival injection failed because the initial fixture is missing.',
    );
  }
  const imaps = { ca, port: endpoints.imapsPort };
  const smtps = { ca, port: endpoints.smtpsPort };
  const credentials = { email: MAILBOX_EMAIL, password: MAILBOX_PASSWORD };
  let smtpTLS = 'unknown';
  try {
    smtpTLS = await sendSMTPSMessage(smtps, credentials, initial.rawMessage);
    await setIMAPMessageFlags({
      credentials,
      endpoint: imaps,
      flags: scenario.preservedState.flags,
      messageID: initial.messageId,
    });
  } catch (error) {
    throw new Error('Incremental-arrival initial injection failed.', {
      cause: error,
    });
  }
  const observed = await observeIncrementalFixture(imaps, credentials, initial);
  const snapshot = await snapshotIMAPMailbox(imaps, credentials);
  assertPreservedInitialState(snapshot, scenario, initial.messageId);
  return { imapTLS: observed.tlsVersion, scenario, smtpTLS };
}

async function coordinateIncrementalArrival(options: {
  ca: string;
  endpoints: Readonly<MailEndpoints>;
  result: Readonly<IncrementalArrivalRunEvidence>;
  runId: string;
  signal?: AbortSignal;
}): Promise<MailClientCoordination> {
  const imaps = { ca: options.ca, port: options.endpoints.imapsPort };
  const smtps = { ca: options.ca, port: options.endpoints.smtpsPort };
  const credentials = { email: MAILBOX_EMAIL, password: MAILBOX_PASSWORD };
  const coordinator = await startMailTestCoordinator({
    onInitialSynchronization: async () => {
      for (const fixture of options.result.scenario.fixtures.filter(
        (candidate) => candidate.stage === 'incremental',
      )) {
        try {
          await sendSMTPSMessage(smtps, credentials, fixture.rawMessage);
        } catch (error) {
          throw new Error(`Injection phase failed for fixture ${fixture.id}.`, {
            cause: error,
          });
        }
        await observeIncrementalFixture(imaps, credentials, fixture);
      }
    },
    runId: options.runId,
    signal: options.signal,
  });
  return {
    close: coordinator.close,
    environment: { MAIL_TEST_COORDINATION_URL: coordinator.url },
    verifyCompleted: async () => {
      await coordinator.verifyCompleted();
      const initial = options.result.scenario.fixtures.find(
        (fixture) =>
          fixture.id === options.result.scenario.preservedState.fixtureId,
      );
      if (initial === undefined) {
        throw new Error(
          'Reconciliation phase could not find the preserved initial fixture.',
        );
      }
      await observeIncrementalFixture(imaps, credentials, initial);
      const snapshot = await snapshotIMAPMailbox(imaps, credentials);
      assertPreservedInitialState(
        snapshot,
        options.result.scenario,
        initial.messageId,
      );
      for (const fixture of options.result.scenario.fixtures.filter(
        (candidate) => candidate.stage === 'incremental',
      )) {
        await observeIncrementalFixture(imaps, credentials, fixture);
      }
    },
  };
}

async function observeIncrementalFixture(
  endpoint: { ca: string; port: number },
  credentials: { email: string; password: string },
  fixture: Readonly<IncrementalArrivalFixture>,
): Promise<IMAPMessageState> {
  try {
    const observed = await readUniqueIMAPMessageState(
      endpoint,
      credentials,
      fixture.messageId,
    );
    if (!observed.raw.includes(`Message-ID: <${fixture.messageId}>`)) {
      throw new Error('message identity did not match');
    }
    return observed;
  } catch (error) {
    throw new Error(
      `Provider-observation phase failed for fixture ${fixture.id}.`,
      { cause: error },
    );
  }
}

function assertPreservedInitialState(
  snapshot: Awaited<ReturnType<typeof snapshotIMAPMailbox>>,
  scenario: Readonly<IncrementalArrivalScenario>,
  messageId: string,
): void {
  const observed = snapshot.messages.find(
    (message) => message.messageId === messageId,
  );
  if (
    !snapshot.mailboxes.includes(scenario.preservedState.mailbox) ||
    observed === undefined ||
    scenario.preservedState.flags.some((flag) => !observed.flags.includes(flag))
  ) {
    throw new Error(
      'Reconciliation phase changed the initial message flags or mailbox placement.',
    );
  }
}

export async function verifyJavaToolchain(signal?: AbortSignal): Promise<void> {
  const result = await runCommand('mise', ['exec', '--', 'java', '-version'], {
    signal,
  });
  const versionOutput = `${result.stdout}\n${result.stderr}`;
  const major = /version "(?<major>\d+)/u.exec(versionOutput)?.groups?.major;
  if (major !== '21') {
    throw new Error(
      'The Mail Test Harness requires repository-managed Java 21. Run `mise install`.',
    );
  }
}

export async function generateCertificate(options: {
  certificatePath: string;
  keystorePath: string;
  passwordPath: string;
  signal?: AbortSignal;
}): Promise<void> {
  await runCommand(
    'mise',
    [
      'exec',
      '--',
      'keytool',
      '-genkeypair',
      '-alias',
      'greenmail',
      '-keyalg',
      'RSA',
      '-keysize',
      '3072',
      '-validity',
      '2',
      '-dname',
      'CN=localhost,OU=Mail Test,O=Unwired,L=Local,ST=Local,C=US',
      '-ext',
      'SAN=dns:localhost,ip:127.0.0.1',
      '-storetype',
      'PKCS12',
      '-keystore',
      options.keystorePath,
      '-storepass:file',
      options.passwordPath,
      '-keypass:file',
      options.passwordPath,
    ],
    { signal: options.signal },
  );
  await runCommand(
    'mise',
    [
      'exec',
      '--',
      'keytool',
      '-exportcert',
      '-rfc',
      '-alias',
      'greenmail',
      '-keystore',
      options.keystorePath,
      '-storepass:file',
      options.passwordPath,
      '-file',
      options.certificatePath,
    ],
    { signal: options.signal },
  );
}

export async function writeJavaArguments(
  argumentFile: string,
  options: {
    apiPort: number;
    artifact: string;
    imapsPort: number;
    keystorePassword: string;
    keystorePath: string;
    smtpsPort: number;
  },
): Promise<void> {
  const javaArguments = [
    '-Djdk.tls.server.protocols=TLSv1.2,TLSv1.3',
    '-Dgreenmail.hostname=127.0.0.1',
    '-Dgreenmail.api.hostname=127.0.0.1',
    `-Dgreenmail.api.port=${String(options.apiPort)}`,
    `-Dgreenmail.imaps.hostname=127.0.0.1`,
    `-Dgreenmail.imaps.port=${String(options.imapsPort)}`,
    `-Dgreenmail.smtps.hostname=127.0.0.1`,
    `-Dgreenmail.smtps.port=${String(options.smtpsPort)}`,
    `-Dgreenmail.users=inbox:${MAILBOX_PASSWORD}@synthetic.invalid`,
    '-Dgreenmail.users.login=email',
    `-Dgreenmail.tls.keystore.file=${options.keystorePath}`,
    `-Dgreenmail.tls.keystore.password=${options.keystorePassword}`,
    `-Dgreenmail.tls.key.password=${options.keystorePassword}`,
    '-Dgreenmail.startup.timeout=5000',
    '-jar',
    options.artifact,
  ];
  await writeFile(
    argumentFile,
    `${javaArguments.map(quoteJavaArgument).join('\n')}\n`,
    { mode: 0o600 },
  );
}

export function syntheticMessage(
  messageID: string,
  subject: string,
  body: string,
): string {
  return [
    'From: sender@synthetic.invalid',
    `To: ${MAILBOX_EMAIL}`,
    `Subject: ${subject}`,
    `Message-ID: <${messageID}>`,
    'Date: Thu, 1 Jan 1970 00:00:00 +0000',
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=utf-8',
    '',
    body,
  ].join('\r\n');
}

function quoteJavaArgument(argument: string): string {
  return JSON.stringify(argument);
}

function appendBounded(chunks: Buffer[], chunk: Buffer): void {
  const bounded = Buffer.concat([...chunks, chunk]).subarray(-8192);
  chunks.splice(0, chunks.length, bounded);
}

function redactDiagnostics(value: string, secrets: readonly string[]): string {
  const credentialRedacted = secrets.reduce(
    (result, secret) => result.replaceAll(secret, '[REDACTED]'),
    value,
  );
  return credentialRedacted
    .replaceAll(MAILBOX_PASSWORD, '[REDACTED]')
    .replaceAll(
      /synthetic-(?:seed|delivery|visible-[a-z-]+)-[0-9a-f-]+/giu,
      '[REDACTED]',
    )
    .replaceAll(
      /Mail Test (?:Archive|Mark Read|Move|Open|Trash)/gu,
      '[REDACTED]',
    )
    .trim();
}

function redactedError(error: unknown, secrets: readonly string[]): Error {
  const originalMessage = unknownErrorMessage(error);
  const message = redactDiagnostics(originalMessage, secrets);
  if (error instanceof MessageContentFixtureError) {
    const prefix = `[fixture: ${error.fixtureId}] `;
    return new MessageContentFixtureError(
      error.fixtureId,
      message.startsWith(prefix) ? message.slice(prefix.length) : message,
    );
  }
  return new Error(message.length > 0 ? message : 'Mail test failed.');
}
