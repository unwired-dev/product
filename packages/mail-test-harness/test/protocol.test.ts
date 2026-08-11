import type { TLSSocket } from 'node:tls';

import { PassThrough } from 'node:stream';
import { connect } from 'node:tls';

import {
  createIMAPMailboxes,
  hasTaggedIMAPResponse,
  inspectIMAPMessage,
  markAllIMAPMessagesSeen,
  readIMAPMessage,
  readUniqueIMAPMessageState,
  sendSMTPSMessage,
  setIMAPMessageFlags,
  snapshotIMAPMailbox,
} from '../src/protocol.ts';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- This Vitest version does not type-check promise-based built-in module mocks.
vi.mock('node:tls', () => ({ connect: vi.fn<typeof connect>() }));

const connectMock = vi.mocked(connect);

describe('imap tagged response framing', () => {
  it('recognizes a tagged completion on the first response line', () => {
    expect.assertions(1);

    expect(hasTaggedIMAPResponse('a001 OK LOGIN completed\r\n', 'a001')).toBe(
      true,
    );
  });

  it('recognizes a tagged completion after untagged responses', () => {
    expect.assertions(1);

    expect(
      hasTaggedIMAPResponse(
        '* 1 EXISTS\r\n* 0 RECENT\r\na001 OK SELECT completed\r\n',
        'a001',
      ),
    ).toBe(true);
  });

  it('does not match a tag prefix collision', () => {
    expect.assertions(1);

    expect({
      matches: hasTaggedIMAPResponse('a0010 OK completed\r\n', 'a001'),
    }).toStrictEqual({ matches: false });
  });
});

describe('mail protocol socket buffering', () => {
  it('creates the scenario mailboxes through authenticated IMAP', async () => {
    expect.assertions(2);
    connectMock.mockReset();
    const fixture = scriptedSocket(
      [Buffer.from('* OK ready\r\n')],
      [
        [Buffer.from('a001 OK LOGIN completed\r\n')],
        [Buffer.from('a002 OK CREATE completed\r\n')],
        [Buffer.from('a003 OK CREATE completed\r\n')],
        [Buffer.from('a004 OK LOGOUT completed\r\n')],
      ],
    );
    useSocket(fixture);

    await expect(
      createIMAPMailboxes(
        { ca: 'test-ca', port: 2993 },
        { email: 'mailbox@example.com', password: 'secret' },
        ['Archive', 'Move Target'],
      ),
    ).resolves.toBeUndefined();
    expect(fixture.writes).toStrictEqual([
      'a001 LOGIN "mailbox@example.com" "secret"\r\n',
      'a002 CREATE "Archive"\r\n',
      'a003 CREATE "Move Target"\r\n',
      'a004 LOGOUT\r\n',
    ]);
  });

  it('inspects independent flags and folder placement without fetching content', async () => {
    expect.assertions(2);
    connectMock.mockReset();
    const fixture = scriptedSocket(
      [Buffer.from('* OK ready\r\n')],
      [
        [Buffer.from('a001 OK LOGIN completed\r\n')],
        [Buffer.from('* 1 EXISTS\r\na002 OK SELECT completed\r\n')],
        [Buffer.from('* SEARCH 4 8\r\na003 OK SEARCH completed\r\n')],
        [
          Buffer.from(
            '* 4 FETCH (UID 4 FLAGS (\\Seen \\Flagged))\r\na004 OK FETCH completed\r\n',
          ),
        ],
        [
          Buffer.from(
            '* 8 FETCH (UID 8 FLAGS ())\r\na005 OK FETCH completed\r\n',
          ),
        ],
        [Buffer.from('* 0 EXISTS\r\na006 OK SELECT completed\r\n')],
        [Buffer.from('* SEARCH\r\na007 OK SEARCH completed\r\n')],
        [Buffer.from('a008 OK LOGOUT completed\r\n')],
      ],
    );
    useSocket(fixture);

    await expect(
      inspectIMAPMessage(
        { ca: 'test-ca', port: 2993 },
        { email: 'mailbox@example.com', password: 'secret' },
        {
          mailboxes: ['INBOX', 'Archive'],
          messageID: 'message-001@synthetic.invalid',
        },
      ),
    ).resolves.toStrictEqual({
      locations: [
        {
          flags: [String.raw`\Flagged`, String.raw`\Seen`],
          mailbox: 'INBOX',
        },
        {
          flags: [],
          mailbox: 'INBOX',
        },
      ],
      tlsVersion: 'TLSv1.3',
    });
    expect(fixture.writes.slice(2, 5)).toStrictEqual([
      'a003 UID SEARCH HEADER Message-ID "<message-001@synthetic.invalid>"\r\n',
      'a004 UID FETCH 4 (FLAGS)\r\n',
      'a005 UID FETCH 8 (FLAGS)\r\n',
    ]);
  });

  it('retains a coalesced SMTP response and decodes split UTF-8', async () => {
    expect.assertions(4);
    connectMock.mockReset();
    const ehloAndAuthentication = Buffer.from(
      '250-café\r\n250 ready\r\n334 VXNlcm5hbWU6\r\n',
    );
    const split = splitInside(ehloAndAuthentication, 'é');
    const fixture = scriptedSocket(
      [Buffer.from('220 ready\r\n')],
      [
        split,
        undefined,
        [Buffer.from('334 UGFzc3dvcmQ6\r\n')],
        [Buffer.from('235 authenticated\r\n')],
        [Buffer.from('250 sender accepted\r\n')],
        [Buffer.from('250 recipient accepted\r\n')],
        [Buffer.from('354 send content\r\n')],
        [Buffer.from('250 queued\r\n')],
        [Buffer.from('221 goodbye\r\n')],
      ],
    );
    useSocket(fixture);

    await expect(
      sendSMTPSMessage(
        { ca: 'test-ca', port: 2465 },
        { email: 'mailbox@example.com', password: 'secret' },
        'Subject: Buffered\r\n\r\nBody',
      ),
    ).resolves.toBe('TLSv1.3');
    expect(fixture.writes.slice(0, 3)).toStrictEqual([
      'EHLO localhost\r\n',
      'AUTH LOGIN\r\n',
      `${Buffer.from('mailbox@example.com').toString('base64')}\r\n`,
    ]);
    expect(fixture.writes).toHaveLength(9);
    expect(fixture.socket.destroyed).toBe(true);
  });

  it('retains a response queued after a maximum-sized SMTP frame', async () => {
    expect.assertions(3);
    connectMock.mockReset();
    const frameLimit = 16 * 1024 * 1024;
    const firstLinePrefix = Buffer.from('250-');
    const finalLine = Buffer.from('\r\n250 ready\r\n');
    const ehloResponse = Buffer.concat([
      firstLinePrefix,
      Buffer.alloc(frameLimit - firstLinePrefix.length - finalLine.length, 'x'),
      finalLine,
    ]);
    const fixture = scriptedSocket(
      [Buffer.from('220 ready\r\n')],
      [
        [Buffer.concat([ehloResponse, Buffer.from('334 VXNlcm5hbWU6\r\n')])],
        undefined,
        [Buffer.from('334 UGFzc3dvcmQ6\r\n')],
        [Buffer.from('235 authenticated\r\n')],
        [Buffer.from('250 sender accepted\r\n')],
        [Buffer.from('250 recipient accepted\r\n')],
        [Buffer.from('354 send content\r\n')],
        [Buffer.from('250 queued\r\n')],
        [Buffer.from('221 goodbye\r\n')],
      ],
    );
    useSocket(fixture);

    await expect(
      sendSMTPSMessage(
        { ca: 'test-ca', port: 2465 },
        { email: 'mailbox@example.com', password: 'secret' },
        'Subject: Buffered\r\n\r\nBody',
      ),
    ).resolves.toBe('TLSv1.3');
    expect(fixture.writes).toHaveLength(9);
    expect(fixture.socket.destroyed).toBe(true);
  });

  it('rejects a malformed SMTP response and destroys the socket', async () => {
    expect.assertions(2);
    connectMock.mockReset();
    const fixture = scriptedSocket([Buffer.from('not SMTP\r\n')], []);
    useSocket(fixture);

    await expect(
      sendSMTPSMessage(
        { ca: 'test-ca', port: 2465 },
        { email: 'mailbox@example.com', password: 'secret' },
        'Subject: Malformed\r\n\r\nBody',
      ),
    ).rejects.toThrow('Malformed SMTP response line');
    expect(fixture.socket.destroyed).toBe(true);
  });

  it('rejects inconsistent SMTP multiline codes and destroys the socket', async () => {
    expect.assertions(2);
    connectMock.mockReset();
    const fixture = scriptedSocket(
      [Buffer.from('220-ready\r\n221 inconsistent\r\n')],
      [],
    );
    useSocket(fixture);

    await expect(
      sendSMTPSMessage(
        { ca: 'test-ca', port: 2465 },
        { email: 'mailbox@example.com', password: 'secret' },
        'Subject: Inconsistent\r\n\r\nBody',
      ),
    ).rejects.toThrow('SMTP multiline response codes did not match');
    expect(fixture.socket.destroyed).toBe(true);
  });

  it('rejects an oversized response frame and destroys the socket', async () => {
    expect.assertions(2);
    connectMock.mockReset();
    const fixture = scriptedSocket(
      [Buffer.alloc(16 * 1024 * 1024 + 1, 'x')],
      [],
    );
    useSocket(fixture);

    await expect(
      sendSMTPSMessage(
        { ca: 'test-ca', port: 2465 },
        { email: 'mailbox@example.com', password: 'secret' },
        'Subject: Oversized\r\n\r\nBody',
      ),
    ).rejects.toThrow('Mail protocol response exceeded the 16 MiB frame limit');
    expect(fixture.socket.destroyed).toBe(true);
  });

  it('uses literal byte lengths and retains a coalesced IMAP response', async () => {
    expect.assertions(5);
    connectMock.mockReset();
    const rawMessage = 'Subject: café\r\n\r\nA naïve body.';
    const greetingAndLogin = Buffer.from(
      '* OK café\r\na001 OK LOGIN completed\r\n',
    );
    const fetchedAndLogout = Buffer.concat([
      Buffer.from(
        `* 7 FETCH (BODY[] {${String(Buffer.byteLength(rawMessage))}}\r\n`,
      ),
      Buffer.from(rawMessage),
      Buffer.from(
        ')\r\na004 OK FETCH completed\r\na005 OK LOGOUT completed\r\n',
      ),
    ]);
    const fixture = scriptedSocket(splitInside(greetingAndLogin, 'é'), [
      undefined,
      [Buffer.from('* 7 EXISTS\r\na002 OK SELECT completed\r\n')],
      [Buffer.from('* SEARCH 7\r\na003 OK SEARCH completed\r\n')],
      splitInside(fetchedAndLogout, 'ï'),
      undefined,
    ]);
    useSocket(fixture);

    await expect(
      readIMAPMessage(
        { ca: 'test-ca', port: 2993 },
        { email: 'mailbox@example.com', password: 'secret' },
        'message-001@synthetic.invalid',
      ),
    ).resolves.toStrictEqual({
      raw: rawMessage,
      sequence: 7,
      tlsVersion: 'TLSv1.3',
    });
    expect(fixture.writes).toHaveLength(5);
    expect(fixture.writes[0]).toBe(
      'a001 LOGIN "mailbox@example.com" "secret"\r\n',
    );
    expect(fixture.writes[4]).toBe('a005 LOGOUT\r\n');
    expect(fixture.socket.destroyed).toBe(true);
  });

  it('reads unique-message flags from INBOX', async () => {
    expect.assertions(3);
    connectMock.mockReset();
    const rawMessage = 'Subject: Incremental\r\n\r\nBody';
    const fixture = scriptedSocket(
      [Buffer.from('* OK ready\r\n')],
      [
        [Buffer.from('a001 OK LOGIN completed\r\n')],
        [Buffer.from('* 7 EXISTS\r\na002 OK SELECT completed\r\n')],
        [Buffer.from('* SEARCH 7\r\na003 OK SEARCH completed\r\n')],
        [
          Buffer.from(
            `* 7 FETCH (FLAGS (\\Seen \\Flagged) BODY[] {${String(Buffer.byteLength(rawMessage))}}\r\n${rawMessage})\r\na004 OK FETCH completed\r\n`,
          ),
        ],
        [Buffer.from('a005 OK LOGOUT completed\r\n')],
      ],
    );
    useSocket(fixture);

    await expect(
      readUniqueIMAPMessageState(
        { ca: 'test-ca', port: 2993 },
        { email: 'mailbox@example.com', password: 'secret' },
        'message-001@synthetic.invalid',
      ),
    ).resolves.toStrictEqual({
      flags: [String.raw`\Seen`, String.raw`\Flagged`],
      raw: rawMessage,
      sequence: 7,
      tlsVersion: 'TLSv1.3',
    });
    expect(fixture.writes[3]).toBe('a004 FETCH 7 (FLAGS BODY.PEEK[])\r\n');
    expect(fixture.socket.destroyed).toBe(true);
  });

  it('sets flags only after resolving one exact message', async () => {
    expect.assertions(2);
    connectMock.mockReset();
    const fixture = scriptedSocket(
      [Buffer.from('* OK ready\r\n')],
      [
        [Buffer.from('a001 OK LOGIN completed\r\n')],
        [Buffer.from('* 4 EXISTS\r\na002 OK SELECT completed\r\n')],
        [Buffer.from('* SEARCH 4\r\na003 OK SEARCH completed\r\n')],
        [Buffer.from('a004 OK STORE completed\r\n')],
        [Buffer.from('a005 OK LOGOUT completed\r\n')],
      ],
    );
    useSocket(fixture);

    await expect(
      setIMAPMessageFlags({
        credentials: { email: 'mailbox@example.com', password: 'secret' },
        endpoint: { ca: 'test-ca', port: 2993 },
        flags: [String.raw`\Flagged`, String.raw`\Seen`],
        messageID: 'message-001@synthetic.invalid',
      }),
    ).resolves.toBeUndefined();
    expect(fixture.writes[3]).toBe(
      'a004 STORE 4 +FLAGS.SILENT (\\Flagged \\Seen)\r\n',
    );
  });

  it.each([
    { searchLine: '* SEARCH', searchResult: '' },
    { searchLine: '* SEARCH 4 7', searchResult: '4 7' },
  ])(
    'rejects a non-unique message identity from SEARCH %j',
    async ({ searchLine }) => {
      expect.assertions(2);
      connectMock.mockReset();
      const fixture = scriptedSocket(
        [Buffer.from('* OK ready\r\n')],
        [
          [Buffer.from('a001 OK LOGIN completed\r\n')],
          [Buffer.from('* 2 EXISTS\r\na002 OK SELECT completed\r\n')],
          [Buffer.from(`${searchLine}\r\na003 OK SEARCH completed\r\n`)],
        ],
      );
      useSocket(fixture);

      await expect(
        readUniqueIMAPMessageState(
          { ca: 'test-ca', port: 2993 },
          { email: 'mailbox@example.com', password: 'secret' },
          'message-001@synthetic.invalid',
        ),
      ).rejects.toThrow('Expected exactly one synthetic IMAP message');
      expect(fixture.socket.destroyed).toBe(true);
    },
  );

  it('rejects duplicate identities before setting flags', async () => {
    expect.assertions(2);
    connectMock.mockReset();
    const fixture = scriptedSocket(
      [Buffer.from('* OK ready\r\n')],
      [
        [Buffer.from('a001 OK LOGIN completed\r\n')],
        [Buffer.from('* 2 EXISTS\r\na002 OK SELECT completed\r\n')],
        [Buffer.from('* SEARCH 4 7\r\na003 OK SEARCH completed\r\n')],
      ],
    );
    useSocket(fixture);

    await expect(
      setIMAPMessageFlags({
        credentials: { email: 'mailbox@example.com', password: 'secret' },
        endpoint: { ca: 'test-ca', port: 2993 },
        flags: [String.raw`\Flagged`, String.raw`\Seen`],
        messageID: 'message-001@synthetic.invalid',
      }),
    ).rejects.toThrow(
      'Expected exactly one synthetic IMAP message before setting flags, found 2.',
    );
    expect(fixture.socket.destroyed).toBe(true);
  });

  it('marks current messages seen while preserving the read-state fixture', async () => {
    expect.assertions(3);
    connectMock.mockReset();
    const fixture = scriptedSocket(
      [Buffer.from('* OK ready\r\n')],
      [
        [Buffer.from('a001 OK LOGIN completed\r\n')],
        [Buffer.from('* 2 EXISTS\r\na002 OK SELECT completed\r\n')],
        [Buffer.from('* SEARCH 3 9\r\na003 OK SEARCH completed\r\n')],
        [Buffer.from('a004 OK STORE completed\r\n')],
        [Buffer.from('a005 OK LOGOUT completed\r\n')],
      ],
    );
    useSocket(fixture);

    await expect(
      markAllIMAPMessagesSeen(
        { ca: 'test-ca', port: 2993 },
        { email: 'mailbox@example.com', password: 'secret' },
        { exceptMessageIds: ['read-state@synthetic.invalid'] },
      ),
    ).resolves.toBeUndefined();
    expect(fixture.writes).toContain(
      'a003 UID SEARCH NOT HEADER Message-ID "<read-state@synthetic.invalid>"\r\n',
    );
    expect(fixture.writes).toContain(
      'a004 UID STORE 3,9 +FLAGS.SILENT (\\Seen)\r\n',
    );
  });

  it('captures stable mailboxes, identities, and persistent flags', async () => {
    expect.assertions(3);
    connectMock.mockReset();
    const rawHeader = 'Message-ID: <fixture@synthetic.invalid>\r\n\r\n';
    const fetched = Buffer.concat([
      Buffer.from(
        `* 1 FETCH (UID 9 FLAGS (\\Seen \\Recent) BODY[HEADER.FIELDS (MESSAGE-ID)] {${String(Buffer.byteLength(rawHeader))}}\r\n`,
      ),
      Buffer.from(rawHeader),
      Buffer.from(')\r\na005 OK FETCH completed\r\n'),
    ]);
    const fixture = scriptedSocket(
      [Buffer.from('* OK ready\r\n')],
      [
        [Buffer.from('a001 OK LOGIN completed\r\n')],
        [
          Buffer.from(
            '* LIST (\\HasNoChildren) "/" "INBOX"\r\na002 OK LIST completed\r\n',
          ),
        ],
        [Buffer.from('* 1 EXISTS\r\na003 OK EXAMINE completed\r\n')],
        [Buffer.from('* SEARCH 9\r\na004 OK SEARCH completed\r\n')],
        [fetched],
        [Buffer.from('a006 OK LOGOUT completed\r\n')],
      ],
    );
    useSocket(fixture);

    await expect(
      snapshotIMAPMailbox(
        { ca: 'test-ca', port: 2993 },
        { email: 'mailbox@example.com', password: 'secret' },
      ),
    ).resolves.toStrictEqual({
      mailboxes: ['INBOX'],
      messages: [
        {
          flags: [String.raw`\Seen`],
          messageId: 'fixture@synthetic.invalid',
          uid: 9,
        },
      ],
    });
    expect(fixture.writes).toStrictEqual([
      'a001 LOGIN "mailbox@example.com" "secret"\r\n',
      'a002 LIST "" "*"\r\n',
      'a003 EXAMINE INBOX\r\n',
      'a004 UID SEARCH ALL\r\n',
      'a005 UID FETCH 9 (UID FLAGS BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])\r\n',
      'a006 LOGOUT\r\n',
    ]);
    expect(fixture.socket.destroyed).toBe(true);
  });
});

interface ScriptedSocketFixture {
  greeting: Buffer[];
  socket: TLSSocket;
  writes: string[];
}

function scriptedSocket(
  greeting: Buffer[],
  responses: Array<Buffer[] | undefined>,
): ScriptedSocketFixture {
  const writes: string[] = [];
  const socket = new PassThrough();
  Object.assign(socket, {
    getProtocol: () => 'TLSv1.3',
    write(value: string | Uint8Array) {
      writes.push(value.toString());
      const response = responses.shift();
      if (response !== undefined) {
        queueMicrotask(() => emitChunks(socket, response));
      }
      return true;
    },
  });
  return {
    greeting,
    // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The Duplex is a deterministic TLSSocket fixture with the used TLS method supplied above.
    socket: socket as unknown as TLSSocket,
    writes,
  };
}

function useSocket(fixture: ScriptedSocketFixture): void {
  connectMock.mockImplementation(() => {
    setImmediate(() => {
      fixture.socket.emit('secureConnect');
      queueMicrotask(() => emitChunks(fixture.socket, fixture.greeting));
    });
    return fixture.socket;
  });
}

function emitChunks(socket: Pick<PassThrough, 'push'>, chunks: Buffer[]): void {
  for (const chunk of chunks) {
    socket.push(chunk);
  }
}

function splitInside(value: Buffer, character: string): Buffer[] {
  const characterStart = value.indexOf(Buffer.from(character));
  if (characterStart === -1) {
    throw new Error(`The split fixture did not contain "${character}".`);
  }
  const split = characterStart + 1;
  return [value.subarray(0, split), value.subarray(split)];
}
