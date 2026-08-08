import type { TLSSocket } from 'node:tls';

import { StringDecoder } from 'node:string_decoder';
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

interface MailFrame {
  bytes: Buffer;
  text: string;
}

interface SocketReadState {
  buffer: Buffer;
  length: number;
  reading: boolean;
}

const maximumMailFrameBytes = 16 * 1024 * 1024;
const maximumQueuedMailBytes = maximumMailFrameBytes * 2;

const socketReadStates = new WeakMap<TLSSocket, SocketReadState>();

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
    await readFrame(socket, findLineEnd);
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
      raw: parseIMAPLiteral(fetched.bytes),
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
      await readFrame(socket, findLineEnd);
      socket.write('readiness LOGOUT\r\n');
      await readFrame(socket, (buffer) =>
        findIMAPResponseEnd(buffer, 'readiness'),
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
  const { text: response } = await readFrame(socket, findSMTPResponseEnd);
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
): Promise<MailFrame> {
  socket.write(`${tag} ${command}\r\n`);
  const response = await readFrame(socket, (buffer) =>
    findIMAPResponseEnd(buffer, tag),
  );
  const taggedLine = response.text
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

async function readFrame(
  socket: TLSSocket,
  findEnd: (buffer: Buffer) => number | undefined,
): Promise<MailFrame> {
  const state = socketReadStates.get(socket) ?? {
    buffer: Buffer.alloc(0),
    length: 0,
    reading: false,
  };
  socketReadStates.set(socket, state);
  if (state.reading) {
    throw new Error(
      'Concurrent reads on one mail protocol socket are invalid.',
    );
  }
  state.reading = true;

  return new Promise<MailFrame>((resolve, reject) => {
    const timeout = setTimeout(() => {
      finish(new Error('Mail protocol response timed out.'));
    }, 5000);
    const onData = (chunk: Buffer): void => {
      try {
        appendChunk(state, chunk);
        finishIfComplete();
      } catch (error) {
        finish(error instanceof Error ? error : new Error(String(error)));
      }
    };
    const onError = (error: Error): void => {
      finish(error);
    };
    const onEnd = (): void => {
      finish(new Error('Mail server closed the connection unexpectedly.'));
    };
    const finishIfComplete = (): void => {
      const end = findEnd(state.buffer.subarray(0, state.length));
      if (end !== undefined) {
        if (end > maximumMailFrameBytes) {
          throw new Error(
            'Mail protocol response exceeded the 16 MiB frame limit.',
          );
        }
        finish(undefined, takeFrame(state, end));
      } else if (state.length > maximumMailFrameBytes) {
        throw new Error(
          'Mail protocol response exceeded the 16 MiB frame limit.',
        );
      }
    };
    const finish = (error?: Error, frame?: Buffer): void => {
      clearTimeout(timeout);
      socket.off('data', onData);
      socket.off('error', onError);
      socket.off('end', onEnd);
      state.reading = false;
      if (error === undefined && frame !== undefined) {
        resolve({ bytes: frame, text: decodeUTF8([frame]) });
      } else {
        reject(error ?? new Error('Mail protocol response was incomplete.'));
      }
    };
    socket.on('data', onData);
    socket.once('error', onError);
    socket.once('end', onEnd);
    try {
      finishIfComplete();
    } catch (error) {
      finish(error instanceof Error ? error : new Error(String(error)));
    }
  });
}

function appendChunk(state: SocketReadState, chunk: Buffer): void {
  const nextLength = state.length + chunk.length;
  if (nextLength > maximumQueuedMailBytes) {
    throw new Error('Mail protocol response queue exceeded the 32 MiB limit.');
  }
  if (nextLength > state.buffer.length) {
    const capacity = Math.min(
      maximumQueuedMailBytes,
      Math.max(nextLength, Math.max(1024, state.buffer.length * 2)),
    );
    const expanded = Buffer.allocUnsafe(capacity);
    state.buffer.copy(expanded, 0, 0, state.length);
    state.buffer = expanded;
  }
  chunk.copy(state.buffer, state.length);
  state.length = nextLength;
}

function findLineEnd(buffer: Buffer): number | undefined {
  const end = buffer.indexOf('\r\n');
  return end === -1 ? undefined : end + 2;
}

function findSMTPResponseEnd(buffer: Buffer): number | undefined {
  let code: string | undefined = undefined;
  let offset = 0;
  while (offset < buffer.length) {
    const lineEnd = buffer.indexOf('\r\n', offset);
    if (lineEnd === -1) {
      return undefined;
    }
    const line = buffer.toString('ascii', offset, lineEnd);
    const match = /^(?<code>\d{3})(?<separator>[ -])/u.exec(line);
    if (match?.groups?.code === undefined) {
      throw new Error(`Malformed SMTP response line: "${line}".`);
    }
    code ??= match.groups.code;
    if (match.groups.code !== code) {
      throw new Error('SMTP multiline response codes did not match.');
    }
    offset = lineEnd + 2;
    if (match.groups.separator === ' ') {
      return offset;
    }
  }
  return undefined;
}

function findIMAPResponseEnd(buffer: Buffer, tag: string): number | undefined {
  let offset = 0;
  while (offset < buffer.length) {
    const lineEnd = buffer.indexOf('\r\n', offset);
    if (lineEnd === -1) {
      return undefined;
    }
    const line = buffer.toString('latin1', offset, lineEnd);
    offset = lineEnd + 2;
    const literal = /\{(?<length>\d+)\+?\}$/u.exec(line);
    if (literal?.groups?.length !== undefined) {
      const literalEnd = offset + Number(literal.groups.length);
      if (buffer.length < literalEnd) {
        return undefined;
      }
      offset = literalEnd;
    } else if (line.startsWith(`${tag} `)) {
      return offset;
    }
  }
  return undefined;
}

function takeFrame(state: SocketReadState, length: number): Buffer {
  if (length > state.length) {
    throw new Error('Mail protocol frame exceeded the buffered byte count.');
  }
  const frame = Buffer.from(state.buffer.subarray(0, length));
  state.buffer.copyWithin(0, length, state.length);
  state.length -= length;
  return frame;
}

function decodeUTF8(chunks: Buffer[]): string {
  const decoder = new StringDecoder('utf8');
  let decoded = '';
  for (const chunk of chunks) {
    decoded += decoder.write(chunk);
  }
  return decoded + decoder.end();
}

function parseSearchSequence(response: MailFrame): number {
  const match = /^\* SEARCH(?: (?<sequence>\d+))?\r?$/mu.exec(response.text);
  if (match?.groups?.sequence === undefined) {
    throw new Error('The expected synthetic message was not present in IMAP.');
  }
  return Number(match.groups.sequence);
}

function parseIMAPLiteral(response: Buffer): string {
  const match = /\{(?<length>\d+)\}\r\n/u.exec(response.toString('latin1'));
  if (match?.groups?.length === undefined || match.index === undefined) {
    throw new Error('The IMAP response did not contain a raw-message literal.');
  }
  const length = Number(match.groups.length);
  const start = match.index + match[0].length;
  return decodeUTF8([response.subarray(start, start + length)]);
}

function quoteIMAP(value: string): string {
  return JSON.stringify(value);
}
