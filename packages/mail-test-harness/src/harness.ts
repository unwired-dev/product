import type { ChildProcess } from 'node:child_process';

import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdtemp, readFile, realpath, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import type { CleanupResult } from './ownership.ts';

import { resolveGreenMailArtifact } from './artifact.ts';
import {
  cleanupOwnedRun,
  createOwnershipRecord,
  persistOwnershipRecord,
  runDirectoryPrefix,
} from './ownership.ts';
import { allocateLoopbackPort, assertLoopbackPortAvailable } from './ports.ts';
import { runCommand, waitForExit } from './process.ts';
import {
  readIMAPMessage,
  sendSMTPSMessage,
  waitForMailServer,
} from './protocol.ts';

const MAILBOX_EMAIL = 'inbox@synthetic.invalid';
const MAILBOX_PASSWORD = 'synthetic-test-password';

export interface SmokeEvidence {
  artifact: {
    checksum: 'verified';
    version: string;
  };
  checks: {
    imapRead: true;
    rawDelivery: true;
    smtpDelivery: true;
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

export async function runCoreMailLoopSmoke(
  signal?: AbortSignal,
): Promise<SmokeEvidence> {
  signal?.throwIfAborted();
  const artifact = await resolveGreenMailArtifact();
  await verifyJavaToolchain(signal);

  const temporaryBase = await realpath(tmpdir());
  const root = await mkdtemp(path.join(temporaryBase, runDirectoryPrefix()));
  let ownership = await createOwnershipRecord(root);
  let child: ChildProcess | undefined = undefined;
  let cleanup: CleanupResult | undefined = undefined;
  const diagnostics: Buffer[] = [];
  const onAbort = (): void => {
    child?.kill('SIGTERM');
  };
  signal?.addEventListener('abort', onAbort, { once: true });

  try {
    const imapsPort = await allocateLoopbackPort();
    let smtpsPort = await allocateLoopbackPort();
    while (smtpsPort === imapsPort) {
      smtpsPort = await allocateLoopbackPort();
    }
    let apiPort = await allocateLoopbackPort();
    while (apiPort === imapsPort || apiPort === smtpsPort) {
      apiPort = await allocateLoopbackPort();
    }
    await assertLoopbackPortAvailable(imapsPort);
    await assertLoopbackPortAvailable(smtpsPort);
    await assertLoopbackPortAvailable(apiPort);

    const keystorePassword = randomBytes(24).toString('base64url');
    const keystorePath = path.join(root, 'greenmail.p12');
    const certificatePath = path.join(root, 'greenmail-ca.pem');
    const passwordPath = path.join(root, 'keystore-password');
    const argumentFile = path.join(root, 'java.args');
    ownership = {
      ...ownership,
      resources: {
        paths: [argumentFile, certificatePath, keystorePath, passwordPath],
        ports: [apiPort, imapsPort, smtpsPort],
      },
    };
    await persistOwnershipRecord(ownership);
    await writeFile(passwordPath, keystorePassword, { mode: 0o600 });
    await generateCertificate({
      certificatePath,
      keystorePath,
      passwordPath,
      signal,
    });
    const ca = await readFile(certificatePath, 'utf8');
    await writeJavaArguments(argumentFile, {
      artifact,
      apiPort,
      imapsPort,
      keystorePassword,
      keystorePath,
      smtpsPort,
    });

    child = spawn('mise', ['exec', '--', 'java', `@${argumentFile}`], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (child.pid === undefined) {
      throw new Error('GreenMail did not expose a process identifier.');
    }
    if (child.stdout === null || child.stderr === null) {
      throw new Error('GreenMail diagnostics were not captured.');
    }
    ownership = {
      ...ownership,
      process: { commandMarker: argumentFile, pid: child.pid },
    };
    await persistOwnershipRecord(ownership);
    child.stdout.on('data', (chunk: Buffer) => {
      appendBounded(diagnostics, chunk);
    });
    child.stderr.on('data', (chunk: Buffer) => {
      appendBounded(diagnostics, chunk);
    });

    const imaps = { ca, port: imapsPort };
    const smtps = { ca, port: smtpsPort };
    await Promise.race([
      waitForMailServer(imaps, signal),
      waitForExit(child).then((exitCode) => {
        throw new Error(
          `GreenMail exited before readiness with status ${String(exitCode)}.`,
        );
      }),
    ]);
    signal?.throwIfAborted();

    const seedID = `${ownership.runId}.seed@synthetic.invalid`;
    const deliveryID = `${ownership.runId}.delivery@synthetic.invalid`;
    const seedBody = `synthetic-seed-${ownership.runId}`;
    const deliveryBody = `synthetic-delivery-${ownership.runId}`;
    const credentials = { email: MAILBOX_EMAIL, password: MAILBOX_PASSWORD };
    const smtpTLS = await sendSMTPSMessage(
      smtps,
      credentials,
      syntheticMessage(seedID, 'Synthetic seed', seedBody),
    );
    const seed = await readIMAPMessage(imaps, credentials, seedID);
    if (!seed.raw.includes(seedBody)) {
      throw new Error(
        'IMAP did not return the expected synthetic seed message.',
      );
    }
    await sendSMTPSMessage(
      smtps,
      credentials,
      syntheticMessage(deliveryID, 'Synthetic SMTP delivery', deliveryBody),
    );
    const delivery = await readIMAPMessage(imaps, credentials, deliveryID);
    if (
      !delivery.raw.includes(deliveryBody) ||
      !delivery.raw.includes(`Message-ID: <${deliveryID}>`)
    ) {
      throw new Error(
        'The delivered raw message did not match the synthetic SMTP submission.',
      );
    }

    cleanup = await cleanupOwnedRun(ownership, child);
    const evidence: SmokeEvidence = {
      artifact: { checksum: 'verified', version: '2.1.12' },
      checks: { imapRead: true, rawDelivery: true, smtpDelivery: true },
      cleanup,
      endpoints: {
        imaps: { host: '127.0.0.1', port: imapsPort, tls: seed.tlsVersion },
        smtps: { host: '127.0.0.1', port: smtpsPort, tls: smtpTLS },
      },
      kind: 'mail-test-evidence',
      runId: ownership.runId,
      scenario: 'core-mail-loop',
      schemaVersion: 1,
      status: 'passed',
    };
    return evidence;
  } catch (error) {
    const diagnosticText = redactDiagnostics(
      Buffer.concat(diagnostics).toString('utf8'),
    );
    if (diagnosticText.length > 0) {
      process.stderr.write(`${diagnosticText}\n`);
    }
    throw error;
  } finally {
    signal?.removeEventListener('abort', onAbort);
    if (cleanup === undefined) {
      await cleanupOwnedRun(ownership, child);
    }
  }
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
  chunks.push(chunk);
  while (Buffer.concat(chunks).byteLength > 8192) {
    chunks.shift();
  }
}

function redactDiagnostics(value: string): string {
  return value
    .replaceAll(MAILBOX_PASSWORD, '[REDACTED]')
    .replaceAll(/synthetic-(?:seed|delivery)-[0-9a-f-]+/giu, '[REDACTED]')
    .trim();
}
