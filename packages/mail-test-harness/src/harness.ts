import type { ChildProcess } from 'node:child_process';

import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';

import type { MessageContentFixture } from './message-content.ts';
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
  markAllIMAPMessagesSeen,
  readIMAPMessage,
  sendSMTPSMessage,
  snapshotIMAPMailbox,
  waitForMailServer,
  waitForSMTPServer,
} from './protocol.ts';

const MAILBOX_EMAIL = 'inbox@synthetic.invalid';
const MAILBOX_PASSWORD = 'synthetic-test-password';
const READ_STATE_FIXTURE_ID = 'plain-text';
const SEEN_FLAG = String.raw`\Seen`;

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
  schemaVersion: 1;
  status: 'passed';
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

export class MessageContentFixtureError extends Error {
  public override name = 'MessageContentFixtureError';
  public readonly fixtureId: string;

  public constructor(fixtureId: string, message: string) {
    super(`[fixture: ${fixtureId}] ${message}`);
    this.fixtureId = fixtureId;
  }
}

interface MailEndpoints {
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

export async function runCoreMailLoopSmoke(
  signal?: AbortSignal,
): Promise<SmokeEvidence> {
  const result = await runOwnedMailTest(signal, async (context) => {
    const mail = await exerciseMailLoop(
      context.endpoints,
      context.ca,
      context.state.ownership.runId,
    );
    await exerciseVisibleMailClient({
      certificatePath: path.join(context.root, 'greenmail-ca.pem'),
      endpoints: context.endpoints,
      root: context.root,
      signal,
      state: context.state,
    });
    return mail;
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
    schemaVersion: 1,
    status: 'passed',
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
  signal?: AbortSignal;
  state: MailTestRunState;
  testCase?: string;
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
    additionalEnvironment: options.additionalEnvironment,
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
    testCase: options.testCase,
  });
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
      readStateMessageId: readStateFixture.messageId,
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
      signal: context.signal,
      state: context.state,
      testCase: 'testMessageContentCorpusInVisibleMailbox',
    });
  } catch (error) {
    throw visibleMessageContentError(error);
  }
}

function visibleMessageContentError(
  error: unknown,
): MessageContentFixtureError {
  if (error instanceof MessageContentFixtureError) {
    return error;
  }
  const message = unknownErrorMessage(error);
  const fixturePrefix = '[fixture: ';
  const fixtureMatch = /\[fixture: [a-z0-9-]+\] /u.exec(message);
  if (fixtureMatch === null) {
    return new MessageContentFixtureError('visible-client', message);
  }
  const fixturePrefixEnd = message.indexOf('] ', fixturePrefix.length);
  const fixtureId = message.slice(fixturePrefix.length, fixturePrefixEnd);
  return new MessageContentFixtureError(
    fixtureId,
    message.replaceAll(`[fixture: ${fixtureId}] `, ''),
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
    readStateMessageId: string;
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
    readStateMessageId: string;
  },
): void {
  const { after, before, readStateMessageId } = snapshots;
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
    assertPreservedMessage(fixture, {
      afterMessage,
      beforeMessage,
      readStateMessageId,
    });
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
    readStateMessageId: string;
  },
): void {
  if (fixture.messageId === state.readStateMessageId) {
    assertExpectedReadState(
      fixture.id,
      state.beforeMessage,
      state.afterMessage,
    );
    return;
  }
  if (
    JSON.stringify(state.beforeMessage) !== JSON.stringify(state.afterMessage)
  ) {
    throw new MessageContentFixtureError(
      fixture.id,
      'Visible presentation changed the server UID, flags, or Message-ID.',
    );
  }
}

function assertExpectedReadState(
  fixtureId: string,
  beforeMessage: IMAPSnapshotMessage,
  afterMessage: IMAPSnapshotMessage,
): void {
  const preservedAfterFlags = afterMessage.flags.filter(
    (flag) => flag !== SEEN_FLAG,
  );
  const transitionIsInvalid = [
    beforeMessage.flags.includes(SEEN_FLAG),
    !afterMessage.flags.includes(SEEN_FLAG),
    beforeMessage.uid !== afterMessage.uid,
    beforeMessage.messageId !== afterMessage.messageId,
    JSON.stringify(beforeMessage.flags) !== JSON.stringify(preservedAfterFlags),
  ].some(Boolean);
  if (transitionIsInvalid) {
    throw new MessageContentFixtureError(
      fixtureId,
      'Visible presentation did not produce the expected read-state transition.',
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

function redactedError(error: unknown, secrets: readonly string[]): Error {
  const originalMessage =
    error instanceof Error ? error.message : String(error);
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
