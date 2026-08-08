import type { TLSSocket } from 'node:tls';

import { connect } from 'node:tls';

interface MailEndpoint {
  ca: string;
  port: number;
}

interface Credentials {
  email: string;
  password: string;
}

export interface IMAPMessage {
  raw: string;
  sequence: number;
  tlsVersion: string;
}

export async function sendSMTPSMessage(
  endpoint: MailEndpoint,
  credentials: Credentials,
  rawMessage: string,
): Promise<string> {
  const socket = await connectTLS(endpoint);
  try {
    await readSMTPResponse(socket, 220);
    await writeSMTPCommand(socket, 'EHLO localhost', 250);
    await writeSMTPCommand(socket, 'AUTH LOGIN', 334);
    await writeSMTPCommand(
      socket,
      Buffer.from(credentials.email).toString('base64'),
      334,
    );
    await writeSMTPCommand(
      socket,
      Buffer.from(credentials.password).toString('base64'),
      235,
    );
    await writeSMTPCommand(socket, `MAIL FROM:<sender@synthetic.invalid>`, 250);
    await writeSMTPCommand(socket, `RCPT TO:<${credentials.email}>`, 250);
    await writeSMTPCommand(socket, 'DATA', 354);
    const normalized = rawMessage
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
    const dotStuffed = normalized
      .split('\n')
      .map((line) => (line.startsWith('.') ? `.${line}` : line))
      .join('\r\n');
    socket.write(`${dotStuffed}\r\n.\r\n`);
    await readSMTPResponse(socket, 250);
    await writeSMTPCommand(socket, 'QUIT', 221);
    return socket.getProtocol() ?? 'unknown';
  } finally {
    socket.destroy();
  }
}

export async function readIMAPMessage(
  endpoint: MailEndpoint,
  credentials: Credentials,
  messageID: string,
): Promise<IMAPMessage> {
  const socket = await connectTLS(endpoint);
  try {
    await readUntil(socket, (response) => response.includes('\r\n'));
    await writeIMAPCommand(
      socket,
      'a001',
      `LOGIN ${quoteIMAP(credentials.email)} ${quoteIMAP(credentials.password)}`,
    );
    await writeIMAPCommand(socket, 'a002', 'SELECT INBOX');
    const search = await writeIMAPCommand(
      socket,
      'a003',
      `SEARCH HEADER Message-ID ${quoteIMAP(`<${messageID}>`)}`,
    );
    const sequence = parseSearchSequence(search);
    const fetched = await writeIMAPCommand(
      socket,
      'a004',
      `FETCH ${String(sequence)} BODY.PEEK[]`,
    );
    await writeIMAPCommand(socket, 'a005', 'LOGOUT');
    return {
      raw: parseIMAPLiteral(fetched),
      sequence,
      tlsVersion: socket.getProtocol() ?? 'unknown',
    };
  } finally {
    socket.destroy();
  }
}

export async function waitForMailServer(
  endpoint: MailEndpoint,
  signal?: AbortSignal,
): Promise<void> {
  await waitForServer({
    endpoint,
    probe: async (socket) => {
      await readUntil(socket, (response) => response.includes('\r\n'));
      socket.write('readiness LOGOUT\r\n');
      await readUntil(socket, (response) =>
        hasTaggedIMAPResponse(response, 'readiness'),
      );
    },
    timeoutMessage: 'GreenMail did not become ready before the timeout.',
    signal,
  });
}

export async function waitForSMTPServer(
  endpoint: MailEndpoint,
  signal?: AbortSignal,
): Promise<void> {
  await waitForServer({
    endpoint,
    probe: async (socket) => {
      await readSMTPResponse(socket, 220);
      await writeSMTPCommand(socket, 'QUIT', 221);
    },
    timeoutMessage: 'GreenMail SMTPS did not become ready before the timeout.',
    signal,
  });
}

async function waitForServer(options: {
  endpoint: MailEndpoint;
  probe: (socket: TLSSocket) => Promise<void>;
  signal?: AbortSignal;
  timeoutMessage: string;
}): Promise<void> {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    options.signal?.throwIfAborted();
    let socket: TLSSocket | undefined = undefined;
    try {
      socket = await connectTLS(options.endpoint);
      await options.probe(socket);
      return;
    } catch {
      await new Promise<void>((resolve) => {
        setTimeout(resolve, 100);
      });
    } finally {
      socket?.destroy();
    }
  }
  throw new Error(options.timeoutMessage);
}

async function connectTLS(endpoint: MailEndpoint): Promise<TLSSocket> {
  return new Promise<TLSSocket>((resolve, reject) => {
    const socket = connect({
      ca: endpoint.ca,
      host: '127.0.0.1',
      minVersion: 'TLSv1.2',
      port: endpoint.port,
      rejectUnauthorized: true,
      servername: 'localhost',
    });
    socket.once('error', reject);
    socket.once('secureConnect', () => {
      socket.off('error', reject);
      resolve(socket);
    });
  });
}

async function writeSMTPCommand(
  socket: TLSSocket,
  command: string,
  expectedCode: number,
): Promise<void> {
  socket.write(`${command}\r\n`);
  await readSMTPResponse(socket, expectedCode);
}

async function readSMTPResponse(
  socket: TLSSocket,
  expectedCode: number,
): Promise<string> {
  const response = await readUntil(socket, (value) => {
    const lines = value.split('\r\n').filter(Boolean);
    return lines.some((line) => /^\d{3} /u.test(line));
  });
  const finalLine = response.trimEnd().split('\r\n').at(-1) ?? '';
  if (!finalLine.startsWith(`${String(expectedCode)} `)) {
    throw new Error(
      `Unexpected SMTP response; expected ${String(expectedCode)}, received "${finalLine}".`,
    );
  }
  return response;
}

async function writeIMAPCommand(
  socket: TLSSocket,
  tag: string,
  command: string,
): Promise<string> {
  socket.write(`${tag} ${command}\r\n`);
  const response = await readUntil(socket, (value) =>
    hasTaggedIMAPResponse(value, tag),
  );
  const taggedLine = response
    .split('\r\n')
    .find((line) => line.startsWith(`${tag} `));
  if (taggedLine === undefined || !taggedLine.startsWith(`${tag} OK`)) {
    throw new Error(`IMAP command ${tag} failed.`);
  }
  return response;
}

export function hasTaggedIMAPResponse(response: string, tag: string): boolean {
  return response.startsWith(`${tag} `) || response.includes(`\r\n${tag} `);
}

async function readUntil(
  socket: TLSSocket,
  complete: (value: string) => boolean,
): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    let response = '';
    const timeout = setTimeout(() => {
      finish(new Error('Mail protocol response timed out.'));
    }, 5000);
    const onData = (chunk: Buffer): void => {
      response += chunk.toString('utf8');
      if (complete(response)) {
        finish();
      }
    };
    const onError = (error: Error): void => {
      finish(error);
    };
    const onEnd = (): void => {
      finish(new Error('Mail server closed the connection unexpectedly.'));
    };
    const finish = (error?: Error): void => {
      clearTimeout(timeout);
      socket.off('data', onData);
      socket.off('error', onError);
      socket.off('end', onEnd);
      if (error === undefined) {
        resolve(response);
      } else {
        reject(error);
      }
    };
    socket.on('data', onData);
    socket.once('error', onError);
    socket.once('end', onEnd);
  });
}

function parseSearchSequence(response: string): number {
  const match = /^\* SEARCH(?: (?<sequence>\d+))?\r?$/mu.exec(response);
  if (match?.groups?.sequence === undefined) {
    throw new Error('The expected synthetic message was not present in IMAP.');
  }
  return Number(match.groups.sequence);
}

function parseIMAPLiteral(response: string): string {
  const match = /\{(?<length>\d+)\}\r\n/u.exec(response);
  if (match?.groups?.length === undefined || match.index === undefined) {
    throw new Error('The IMAP response did not contain a raw-message literal.');
  }
  const length = Number(match.groups.length);
  const start = match.index + match[0].length;
  return Buffer.from(response, 'utf8')
    .subarray(
      Buffer.byteLength(response.slice(0, start)),
      Buffer.byteLength(response.slice(0, start)) + length,
    )
    .toString('utf8');
}

function quoteIMAP(value: string): string {
  return JSON.stringify(value);
}
