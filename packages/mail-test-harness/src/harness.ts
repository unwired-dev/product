import type { ChildProcess } from 'node:child_process';

import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import type { CleanupResult, OwnershipRecord } from './ownership.ts';

import {
  createMailTestSimulator,
  deleteOwnedSimulator,
  mailTestSimulatorIntent,
  prepareMailTestSimulator,
  runMailTestApplication,
} from './apple.ts';
import { resolveGreenMailArtifact } from './artifact.ts';
import {
  cleanupOwnedRun,
  createOwnershipRecord,
  persistOwnershipRecord,
  runDirectoryPrefix,
} from './ownership.ts';
import { allocateLoopbackPort } from './ports.ts';
import { runCommand, terminateProcess, waitForExit } from './process.ts';
import {
  readIMAPMessage,
  sendSMTPSMessage,
  waitForMailServer,
  waitForSMTPServer,
} from './protocol.ts';

const MAILBOX_EMAIL = 'inbox@synthetic.invalid';
const MAILBOX_PASSWORD = 'synthetic-test-password';

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
  schemaVersion: 1;
  status: 'passed';
}

interface MailEndpoints {
  apiPort: number;
  imapsPort: number;
  smtpsPort: number;
}

interface SmokeRunState {
  child?: ChildProcess;
  cleanup?: CleanupResult;
  diagnostics: Buffer[];
  diagnosticSecrets: string[];
  ownership: OwnershipRecord;
}

export async function runCoreMailLoopSmoke(
  signal?: AbortSignal,
): Promise<SmokeEvidence> {
  signal?.throwIfAborted();
  const artifact = await resolveGreenMailArtifact({ signal });
  await verifyJavaToolchain(signal);

  const temporaryBase = await realpath(tmpdir());
  const root = await mkdtemp(path.join(temporaryBase, runDirectoryPrefix()));
  const ownership = await createSmokeOwnership(root);
  const state: SmokeRunState = {
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
    const mail = await exerciseMailLoop(endpoints, ca, state.ownership.runId);
    await exerciseVisibleMailClient({
      certificatePath: path.join(root, 'greenmail-ca.pem'),
      endpoints,
      root,
      signal,
      state,
    });
    state.cleanup = await cleanupOwnedRun(state.ownership, state.child);
    return {
      artifact: { checksum: 'verified', version: '2.1.12' },
      checks: {
        appBootstrap: true,
        imapRead: true,
        rawDelivery: true,
        smtpDelivery: true,
        visibleSeed: true,
      },
      cleanup: state.cleanup,
      endpoints: {
        imaps: {
          host: '127.0.0.1',
          port: endpoints.imapsPort,
          tls: mail.imapTLS,
        },
        smtps: {
          host: '127.0.0.1',
          port: endpoints.smtpsPort,
          tls: mail.smtpTLS,
        },
      },
      kind: 'mail-test-evidence',
      runId: state.ownership.runId,
      scenario: 'core-mail-loop',
      schemaVersion: 1,
      status: 'passed',
    };
  } catch (error) {
    const diagnosticText = redactDiagnostics(
      Buffer.concat(state.diagnostics).toString('utf8'),
      state.diagnosticSecrets,
    );
    if (diagnosticText.length > 0) {
      process.stderr.write(`${diagnosticText}\n`);
    }
    throw error;
  } finally {
    signal?.removeEventListener('abort', onAbort);
    await cleanupFailedSmokeRun(state);
  }
}

async function exerciseVisibleMailClient(options: {
  certificatePath: string;
  endpoints: Readonly<MailEndpoints>;
  root: string;
  signal?: AbortSignal;
  state: SmokeRunState;
}): Promise<void> {
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
    certificatePath: options.certificatePath,
    host: '127.0.0.1',
    imapsPort: options.endpoints.imapsPort,
    runId: options.state.ownership.runId,
    signal: options.signal,
    smtpsPort: options.endpoints.smtpsPort,
  });
  await runMailTestApplication({
    root: options.root,
    signal: options.signal,
    simulator,
  });
}

async function cleanupFailedSmokeRun(state: SmokeRunState): Promise<void> {
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

async function allocateMailEndpoints(): Promise<MailEndpoints> {
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
  state: SmokeRunState;
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
  state: SmokeRunState;
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
  state: SmokeRunState,
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
  state: SmokeRunState,
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

async function waitForGreenMailReadiness(
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
): Promise<{ imapTLS: string; smtpTLS: string }> {
  const imaps = { ca, port: endpoints.imapsPort };
  const smtps = { ca, port: endpoints.smtpsPort };
  const seedID = `${runId}.seed@synthetic.invalid`;
  const deliveryID = `${runId}.delivery@synthetic.invalid`;
  const seedBody = `synthetic-seed-${runId}`;
  const deliveryBody = `synthetic-delivery-${runId}`;
  const credentials = { email: MAILBOX_EMAIL, password: MAILBOX_PASSWORD };
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
  return { imapTLS: seed.tlsVersion, smtpTLS };
}

async function verifyJavaToolchain(signal?: AbortSignal): Promise<void> {
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

async function generateCertificate(options: {
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

async function writeJavaArguments(
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

function syntheticMessage(
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
    .replaceAll(/synthetic-(?:seed|delivery)-[0-9a-f-]+/giu, '[REDACTED]')
    .trim();
}
