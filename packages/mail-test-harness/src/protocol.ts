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

export interface IMAPMessageState extends IMAPMessage {
  flags: string[];
}

export interface IMAPMailboxSnapshot {
  mailboxes: string[];
  messages: Array<{
    flags: string[];
    messageId: string;
    uid: number;
  }>;
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
  return withAuthenticatedIMAPSession(endpoint, credentials, async (socket) => {
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
  });
}

export async function markAllIMAPMessagesSeen(
  endpoint: MailEndpoint,
  credentials: Credentials,
  options: { exceptMessageIds?: readonly string[] } = {},
): Promise<void> {
  await withAuthenticatedIMAPSession(endpoint, credentials, async (socket) => {
    await writeIMAPCommand(socket, 'a002', 'SELECT INBOX');
    const excluded = options.exceptMessageIds ?? [];
    const query =
      excluded.length === 0
        ? 'ALL'
        : excluded
            .map(
              (messageId) =>
                `NOT HEADER Message-ID ${quoteIMAP(`<${messageId}>`)}`,
            )
            .join(' ');
    const search = await writeIMAPCommand(
      socket,
      'a003',
      `UID SEARCH ${query}`,
    );
    const uids = parseSearchUIDs(search);
    if (uids.length > 0) {
      await writeIMAPCommand(
        socket,
        'a004',
        `UID STORE ${uids.join(',')} +FLAGS.SILENT (\\Seen)`,
      );
    }
    await writeIMAPCommand(socket, 'a005', 'LOGOUT');
  });
}

export async function snapshotIMAPMailbox(
  endpoint: MailEndpoint,
  credentials: Credentials,
): Promise<IMAPMailboxSnapshot> {
  return withAuthenticatedIMAPSession(endpoint, credentials, async (socket) => {
    const listed = await writeIMAPCommand(socket, 'a002', 'LIST "" "*"');
    await writeIMAPCommand(socket, 'a003', 'EXAMINE INBOX');
    const search = await writeIMAPCommand(socket, 'a004', 'UID SEARCH ALL');
    const messages: IMAPMailboxSnapshot['messages'] = [];
    let tagNumber = 5;
    for (const uid of parseSearchUIDs(search)) {
      const fetched = await writeIMAPCommand(
        socket,
        `a${String(tagNumber).padStart(3, '0')}`,
        `UID FETCH ${String(uid)} (UID FLAGS BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])`,
      );
      messages.push(parseSnapshotMessage(fetched));
      tagNumber += 1;
    }
    await writeIMAPCommand(
      socket,
      `a${String(tagNumber).padStart(3, '0')}`,
      'LOGOUT',
    );
    return {
      mailboxes: listed.text
        .split('\r\n')
        .filter((line) => line.toUpperCase().startsWith('* LIST '))
        .map(parseMailboxName)
        .toSorted(),
      messages: messages.toSorted((first, second) => first.uid - second.uid),
    };
  });
}

async function withAuthenticatedIMAPSession<T>(
  endpoint: MailEndpoint,
  credentials: Credentials,
  operation: (socket: TLSSocket) => Promise<T>,
): Promise<T> {
  const socket = await connectTLS(endpoint);
  try {
    await readFrame(socket, findLineEnd);
    await writeIMAPCommand(
      socket,
      'a001',
      `LOGIN ${quoteIMAP(credentials.email)} ${quoteIMAP(credentials.password)}`,
    );
    return await operation(socket);
  } finally {
    socket.destroy();
  }
}

export async function readUniqueIMAPMessageState(
  endpoint: MailEndpoint,
  credentials: Credentials,
  messageID: string,
): Promise<IMAPMessageState> {
  return withAuthenticatedIMAPSession(endpoint, credentials, async (socket) => {
    await writeIMAPCommand(socket, 'a002', 'SELECT INBOX');
    const search = await writeIMAPCommand(
      socket,
      'a003',
      `SEARCH HEADER Message-ID ${quoteIMAP(`<${messageID}>`)}`,
    );
    const sequence = parseUniqueSearchSequence(search);
    const fetched = await writeIMAPCommand(
      socket,
      'a004',
      `FETCH ${String(sequence)} (FLAGS BODY.PEEK[])`,
    );
    await writeIMAPCommand(socket, 'a005', 'LOGOUT');
    return {
      flags: parseIMAPFlags(fetched.text, sequence),
      raw: parseIMAPLiteral(fetched.bytes),
      sequence,
      tlsVersion: socket.getProtocol() ?? 'unknown',
    };
  });
}

export async function setIMAPMessageFlags(options: {
  credentials: Credentials;
  endpoint: MailEndpoint;
  flags: readonly [string, string];
  messageID: string;
}): Promise<void> {
  await withAuthenticatedIMAPSession(
    options.endpoint,
    options.credentials,
    async (socket) => {
      await writeIMAPCommand(socket, 'a002', 'SELECT INBOX');
      const search = await writeIMAPCommand(
        socket,
        'a003',
        `SEARCH HEADER Message-ID ${quoteIMAP(`<${options.messageID}>`)}`,
      );
      const sequence = parseUniqueSearchSequence(
        search,
        ' before setting flags',
      );
      await writeIMAPCommand(
        socket,
        'a004',
        `STORE ${String(sequence)} +FLAGS.SILENT (${options.flags.join(' ')})`,
      );
      await writeIMAPCommand(socket, 'a005', 'LOGOUT');
    },
  );
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
  const sequences = parseSearchSequences(response);
  const [sequence] = sequences;
  if (sequence === undefined) {
    throw new Error('The expected synthetic message was not present in IMAP.');
  }
  return sequence;
}

function parseSearchSequences(response: MailFrame): number[] {
  const match = /^\* SEARCH(?<sequences>(?: \d+)*)\r?$/mu.exec(response.text);
  if (match?.groups?.sequences === undefined) {
    throw new Error('The IMAP search response was malformed.');
  }
  const value = match.groups.sequences.trim();
  return value === '' ? [] : value.split(' ').map(Number);
}

function parseUniqueSearchSequence(response: MailFrame, context = ''): number {
  const sequences = parseSearchSequences(response);
  const sequence = sequences.length === 1 ? sequences[0] : undefined;
  if (sequence === undefined) {
    throw new Error(
      `Expected exactly one synthetic IMAP message${context}, found ${String(sequences.length)}.`,
    );
  }
  return sequence;
}

function parseIMAPFlags(response: string, sequence: number): string[] {
  const match = new RegExp(
    `^\\* ${String(sequence)} FETCH \\(FLAGS \\((?<flags>[^)]*)\\)`,
    'mu',
  ).exec(response);
  if (match?.groups?.flags === undefined) {
    throw new Error('The IMAP response did not contain message flags.');
  }
  const flags = match.groups.flags.trim();
  return flags === '' ? [] : flags.split(' ');
}

function parseSearchUIDs(response: MailFrame): number[] {
  const line = response.text
    .split('\r\n')
    .find((candidate) => candidate.toUpperCase().startsWith('* SEARCH'));
  if (line === undefined) {
    throw new Error('The IMAP search response was missing.');
  }
  return line.split(' ').slice(2).map(Number).filter(Number.isSafeInteger);
}

function parseSnapshotMessage(response: MailFrame): {
  flags: string[];
  messageId: string;
  uid: number;
} {
  const uid = /\bUID\s+(?<uid>\d+)/iu.exec(response.text)?.groups?.uid;
  const flags = /\bFLAGS\s+\((?<flags>[^)]*)\)/iu.exec(response.text)?.groups
    ?.flags;
  const literal = parseIMAPLiteral(response.bytes);
  const messageId = /^Message-ID:\s*<(?<messageId>[^<>\s]+)>\s*$/imu.exec(
    literal,
  )?.groups?.messageId;
  if (uid === undefined || flags === undefined || messageId === undefined) {
    throw new Error('The IMAP mailbox snapshot response was invalid.');
  }
  return {
    flags: flags
      .split(/\s+/u)
      .filter(
        (flag) => flag.length > 0 && flag.toUpperCase() !== String.raw`\RECENT`,
      )
      .toSorted((first, second) => first.localeCompare(second)),
    messageId,
    uid: Number(uid),
  };
}

function parseMailboxName(line: string): string {
  const mailbox = /\s(?<mailbox>"(?:[^"\\]|\\.)*"|[^\s]+)$/u.exec(line)?.groups
    ?.mailbox;
  if (mailbox === undefined) {
    throw new Error('The IMAP mailbox list response was invalid.');
  }
  if (mailbox.startsWith('"')) {
    const decoded: unknown = JSON.parse(mailbox);
    if (typeof decoded !== 'string') {
      throw new TypeError('The IMAP mailbox list response was invalid.');
    }
    return decoded;
  }
  return mailbox;
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
