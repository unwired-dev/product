// Synthetic protocol fixture, used only by the hosted vault test runner on an owned simulator.
/* eslint-disable node/no-sync -- Certificate setup and runner evidence must finish before announcing readiness or exit. */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import tls from 'node:tls';

const [directory] = process.argv.slice(2);
assert.ok(directory, 'Expected the runner-owned fixture directory');
const file = (name) => path.join(directory, name);
const openssl = (...args) => execFileSync('openssl', args, { stdio: 'ignore' });
openssl(
  'req',
  '-x509',
  '-newkey',
  'rsa:2048',
  '-nodes',
  '-days',
  '1',
  '-subj',
  '/CN=Unwired Synthetic IMAP CA',
  '-addext',
  'basicConstraints=critical,CA:TRUE',
  '-keyout',
  file('ca.key'),
  '-out',
  file('ca.pem'),
);
openssl(
  'req',
  '-newkey',
  'rsa:2048',
  '-nodes',
  '-subj',
  '/CN=localhost',
  '-keyout',
  file('server.key'),
  '-out',
  file('server.csr'),
);
writeFileSync(
  file('server.ext'),
  [
    'basicConstraints=critical,CA:FALSE',
    'subjectAltName=DNS:localhost',
    'extendedKeyUsage=serverAuth',
  ].join('\n'),
);
openssl(
  'x509',
  '-req',
  '-in',
  file('server.csr'),
  '-CA',
  file('ca.pem'),
  '-CAkey',
  file('ca.key'),
  '-CAcreateserial',
  '-days',
  '1',
  '-extfile',
  file('server.ext'),
  '-out',
  file('server.pem'),
);

const raw = Buffer.from(
  'Subject: Controlled IMAP\r\nContent-Type: text/plain\r\n\r\nControlled body\r\n',
);
// UIDNEXT per folder: a large folder with old uncached messages, and a small one after arrivals
// were expunged.
const uidNexts = { Large: 512, Sparse: 402 };
const uidNextOf = (command) =>
  Object.entries(uidNexts).find(([folder]) => command.includes(folder))?.[1] ??
  12;
// The metadata a FETCH asks for, for the message it names.
// fallow-ignore-next-line complexity -- Exercised by the hosted native TLS test; the static JS test graph cannot see its real SwiftMail callers.
const metadataFields = (command, uid) => [
  `UID ${uid}`,
  ...(command.includes('FLAGS') ? [String.raw`FLAGS (\Flagged)`] : []),
  ...(command.includes('RFC822.SIZE') ? [`RFC822.SIZE ${raw.length}`] : []),
  ...(command.includes('INTERNALDATE')
    ? ['INTERNALDATE "11-Oct-2026 10:00:00 +0000"']
    : []),
  ...(command.includes('ENVELOPE')
    ? [
        'ENVELOPE ("11 Oct 2026 10:00:00 +0000" "Controlled IMAP" (("Synthetic Sender" NIL "sender" "example.invalid")) NIL NIL NIL NIL NIL NIL "<controlled@example.invalid>")',
      ]
    : []),
];
// A resumed folder lists envelopes only for what arrived since its checkpoint.
const assertResumed = (command, { large, sparse }) => {
  if (!command.includes('ENVELOPE')) {
    return;
  }
  assert.ok(
    !large,
    'A resumed folder without arrivals must not list its newest messages again',
  );
  if (sparse) {
    assert.match(command, /^UID FETCH 12:\* /u);
  }
};
const operations = new Set();
// Sent copies appended by MIME boundary; filing the same message again must find, not append.
const appended = new Set();
const discoverNamespaces = (socket, tag, failed) => {
  if (failed) {
    operations.add('namespace-refused');
    socket.write(`${tag} NO Namespace temporarily unavailable\r\n`);
  } else {
    operations.add('namespace');
    socket.write(
      `* NAMESPACE (("" "/")) NIL (("Shared/" "/"))\r\n${tag} OK Completed\r\n`,
    );
  }
};
const listFolders = (socket, command, overflowing) => {
  operations.add('list');
  if (overflowing) {
    operations.add('folder-overflow');
    socket.write(
      Array.from(
        { length: 1001 },
        (_, index) => `* LIST (\\HasNoChildren) "/" "Folder ${index}"\r\n`,
      ).join(''),
    );
  } else if (command.includes('Shared/')) {
    operations.add('shared-list');
    socket.write('* LIST (\\HasNoChildren) "/" "Shared/Team"\r\n');
  } else if (!command.includes('Shared')) {
    socket.write(
      // The reserved ASCII name folds case; a Unicode lookalike and an inbox role do not.
      '* LIST (\\HasNoChildren) "/" "Inbox"\r\n* LIST (\\HasNoChildren \\Archive) "/" "Archive"\r\n* LIST (\\HasNoChildren) "/" "ınbox"\r\n* LIST (\\HasNoChildren \\Inbox) "/" "Primary"\r\n',
    );
  }
};
// What each synthetic user's server advertises: organizing needs MOVE, or UIDPLUS for a targeted
// expunge; waiting needs IDLE.
const capabilitiesOf = (user, namespaces) =>
  [
    'IMAP4rev1',
    ...(namespaces ? ['NAMESPACE'] : []),
    ...({
      synthetic: ['MOVE', 'UIDPLUS', 'IDLE'],
      'no-move': ['UIDPLUS'],
      'large-search': ['ESEARCH'],
    }[user] ?? []),
  ].join(' ');
// Folders the server no longer selects, and a destination it refuses.
const gone = /(?:^|[ "])Gone"?$/u;
let copies = 0;
// Organizing commands on the selected folder: read state, MOVE, and COPY with a UID EXPUNGE.
// fallow-ignore-next-line complexity -- Exercised by the hosted native TLS test; the static JS test graph cannot see its real SwiftMail callers.
const organize = (socket, tag, command) => {
  if (/^UID STORE 11 [+-]FLAGS(?:\.SILENT)? \(\\Seen\)$/u.test(command)) {
    operations.add(command.includes('+FLAGS') ? 'store-seen' : 'store-unseen');
    socket.write(`${tag} OK Stored\r\n`);
  } else if (
    /^UID STORE 11 \+FLAGS(?:\.SILENT)? \(\\Deleted\)$/u.test(command)
  ) {
    operations.add('store-deleted');
    socket.write(`${tag} OK Stored\r\n`);
  } else if (/^UID MOVE 11 "?Missing"?$/u.test(command)) {
    operations.add('move-refused');
    socket.write(`${tag} NO [TRYCREATE] No such mailbox\r\n`);
  } else if (/^UID MOVE 11 "?Drop"?$/u.test(command)) {
    // The connection drops after the change was sent, as a lost reply.
    operations.add('move-dropped');
    socket.destroy();
  } else if (/^UID MOVE 11 "?Partial"?$/u.test(command)) {
    operations.add('move-partial');
    socket.write(
      `* OK [COPYUID 9 11 24] Copied\r\n${tag} NO Partial completion\r\n`,
    );
  } else if (/^UID MOVE 11 "?Archive"?$/u.test(command)) {
    operations.add('move');
    socket.write(
      `* OK [COPYUID 9 11 21] Moved\r\n* 1 EXPUNGE\r\n${tag} OK Done\r\n`,
    );
  } else if (/^UID COPY 11 "?Archive"?$/u.test(command)) {
    copies += 1;
    assert.equal(copies, 1, 'Resuming a copy receipt must never copy again');
    operations.add('copy');
    socket.write(`${tag} OK [COPYUID 9 11 22] Copied\r\n`);
  } else if (/^UID COPY 11 "?Unmapped"?$/u.test(command)) {
    operations.add('copy-unmapped');
    socket.write(`${tag} OK Copied without receipt\r\n`);
  } else if (/^UID COPY 11 "?DropCopy"?$/u.test(command)) {
    operations.add('copy-dropped');
    socket.destroy();
  } else if (command === 'UID EXPUNGE 11') {
    operations.add('expunge');
    socket.write(`* 1 EXPUNGE\r\n${tag} OK Expunged\r\n`);
  } else {
    // A plain EXPUNGE would remove other clients' deleted messages too.
    assert.fail(`Unexpected organizing command: ${command}`);
  }
};
// The user name a LOGIN presents, which chooses the synthetic server's variation.
const userOf = (command) =>
  /^LOGIN "?(?<name>[\w-]+)"? /u.exec(command)?.groups?.name ?? '';
// SELECT for organizing, EXAMINE for reading; a removed folder refuses both.
// fallow-ignore-next-line complexity -- Exercised by the hosted native TLS test; the static JS test graph cannot see its real SwiftMail callers.
const selectFolder = (socket, session, { tag, command }) => {
  if (gone.test(command)) {
    operations.add('gone');
    socket.write(`${tag} NO Mailbox does not exist\r\n`);
    return;
  }
  const writable = command.startsWith('SELECT ');
  operations.add(writable ? 'select' : 'examine');
  session.selected = command
    .slice(command.indexOf(' ') + 1)
    .replaceAll('"', '');
  session.identified = !command.includes('NoValidity');
  session.large = command.includes('Large');
  session.sparse = command.includes('Sparse');
  if (!session.identified) {
    operations.add('unidentified');
  }
  socket.write(
    `* FLAGS (\\Flagged)\r\n* ${session.large ? 500 : 1} EXISTS\r\n* 0 RECENT\r\n${session.identified ? `* OK [UIDVALIDITY ${session.selected === 'Archive' ? 9 : 7}] Stable\r\n` : ''}* OK [UIDNEXT ${uidNextOf(command)}] Next\r\n`,
  );
  socket.write(
    writable
      ? `${tag} OK [READ-WRITE] Selected\r\n`
      : `${tag} OK [READ-ONLY] Examined\r\n`,
  );
};
// Commands beyond reading: selecting, organizing on the selected Inbox, a UID the folder no
// longer holds, search, and IDLE with its DONE. Returns false for any other command.
// fallow-ignore-next-line complexity -- Exercised by the hosted native TLS test; the static JS test graph cannot see its real SwiftMail callers.
const answerChange = (socket, session, { tag, command }) => {
  if (command === 'DONE') {
    assert.ok(session.idling, 'DONE outside IDLE');
    operations.add('idle-done');
    socket.write(`${session.idling} OK Idle terminated\r\n`);
    session.idling = '';
  } else if (/^(?:EXAMINE|SELECT) /u.test(command)) {
    selectFolder(socket, session, { tag, command });
  } else if (
    command.startsWith('UID FETCH 13 ') ||
    command.startsWith('UID FETCH 23 ')
  ) {
    operations.add('absent');
    socket.write(`${tag} OK Completed\r\n`);
  } else if (/^UID (?:STORE|MOVE|COPY|EXPUNGE) /u.test(command)) {
    assert.equal(session.selected, 'INBOX', 'Organizing needs the Inbox');
    organize(socket, tag, command);
  } else if (command.startsWith('UID FETCH 22 ')) {
    assert.equal(session.selected, 'Archive');
    socket.write(`* 1 FETCH (UID 22 FLAGS ())\r\n${tag} OK Completed\r\n`);
  } else if (command.startsWith('UID FETCH 3999999951:4000000000 ')) {
    assert.equal(session.user, 'large-search');
    operations.add('bounded-search-fetch');
    socket.write(
      `* 1 FETCH (${metadataFields(command, 4_000_000_000).join(' ')})\r\n${tag} OK Completed\r\n`,
    );
  } else if (/^UID SEARCH .*HEADER/u.test(command)) {
    // A Sent copy is found by its MIME boundary in Content-Type.
    assert.equal(session.selected, 'Sent');
    const boundary =
      /HEADER "?Content-Type"? "?(?<boundary>[\w=.-]+)"?$/iu.exec(command)
        ?.groups?.boundary;
    assert.ok(boundary, `Unexpected Sent search: ${command}`);
    operations.add(appended.has(boundary) ? 'sent-found' : 'sent-search');
    socket.write(
      `* SEARCH${appended.has(boundary) ? ' 31' : ''}\r\n${tag} OK Completed\r\n`,
    );
  } else if (command.startsWith('UID SEARCH ')) {
    assert.match(command, /TEXT "?Controlled"?$/u);
    operations.add('search');
    if (session.user === 'large-search') {
      operations.add('large-search');
      socket.write(
        `* ESEARCH (TAG "${tag}") UID ALL 1:4000000000\r\n${tag} OK Completed\r\n`,
      );
    } else {
      socket.write(`* SEARCH 11\r\n${tag} OK Completed\r\n`);
    }
  } else if (command === 'IDLE') {
    operations.add('idle');
    session.idling = tag;
    socket.write('+ idling\r\n');
    // The Inbox receives mail while waited on; Quiet never changes.
    if (session.selected === 'INBOX') {
      setTimeout(() => {
        socket.write('* 2 EXISTS\r\n');
      }, 100);
    }
  } else {
    return false;
  }
  return true;
};
const sockets = new Set();
let connected = 0;
let closed = 0;
const server = tls.createServer(
  {
    key: readFileSync(file('server.key')),
    cert: readFileSync(file('server.pem')),
    minVersion: 'TLSv1.2',
  },
  (socket) => {
    assert.ok(['TLSv1.2', 'TLSv1.3'].includes(socket.getProtocol()));
    connected += 1;
    sockets.add(socket);
    socket.on('close', () => {
      sockets.delete(socket);
      closed += 1;
    });
    socket.on('error', () => {
      socket.destroy();
    });
    socket.write('* OK [CAPABILITY IMAP4rev1] Controlled server ready\r\n');
    let input = '';
    let overflowing = false;
    let namespaces = false;
    let namespaceFailure = false;
    let user = '';
    const session = {
      user: '',
      selected: '',
      idling: '',
      identified: false,
      large: false,
      sparse: false,
      literal: undefined,
    };
    // fallow-ignore-next-line complexity -- Exercised by the hosted native TLS test; the static JS test graph cannot see its real SwiftMail callers.
    socket.on('data', (bytes) => {
      input += bytes.toString('ascii');
      assert.ok(input.length <= 8192, 'Fixture command exceeded its bound');
      let end = -1;
      // An APPEND's message arrives as a literal after the continuation request.
      while (
        session.literal === undefined
          ? (end = input.indexOf('\r\n')) !== -1
          : input.length >= session.literal.size + 2
      ) {
        if (session.literal !== undefined) {
          const { tag, size } = session.literal;
          const message = input.slice(0, size);
          input = input.slice(size + 2);
          session.literal = undefined;
          const boundary = /boundary="(?<boundary>[^"]+)"/u.exec(message)
            ?.groups?.boundary;
          assert.ok(
            boundary,
            'An appended Sent copy carries its MIME boundary',
          );
          assert.ok(
            !appended.has(boundary),
            'A Sent copy must never be appended twice',
          );
          appended.add(boundary);
          operations.add('append');
          socket.write(`${tag} OK [APPENDUID 9 31] Appended\r\n`);
          continue;
        }
        const line = input.slice(0, end);
        input = input.slice(end + 2);
        const separator = line.indexOf(' ');
        const tag = line.slice(0, separator);
        const command = line.slice(separator + 1);
        const ok = () => socket.write(`${tag} OK Completed\r\n`);
        const literal = /^APPEND "?Sent"? \(\\Seen\) \{(?<size>\d+)\}$/u.exec(
          command,
        );
        if (literal?.groups?.size !== undefined) {
          session.literal = { tag, size: Number(literal.groups.size) };
          socket.write('+ Ready for the message\r\n');
        } else if (answerChange(socket, session, { tag, command })) {
          // Answered above.
        } else if (command === 'CAPABILITY') {
          socket.write(`* CAPABILITY ${capabilitiesOf(user, namespaces)}\r\n`);
          ok();
        } else if (command.startsWith('LOGIN ')) {
          if (command.includes('refused')) {
            operations.add('refused');
            socket.write(`${tag} NO [AUTHENTICATIONFAILED] Refused\r\n`);
          } else {
            assert.match(command, /synthetic-password/u);
            user = userOf(command);
            session.user = user;
            overflowing = command.includes('many-folders');
            namespaceFailure = command.includes('namespace-failure');
            namespaces = ['namespace-failure', 'namespaced'].some((name) =>
              command.includes(name),
            );
            ok();
          }
        } else if (command === 'NAMESPACE') {
          discoverNamespaces(socket, tag, namespaceFailure);
        } else if (command.startsWith('LIST ')) {
          listFolders(socket, command, overflowing);
          ok();
        } else if (/^(?:UID )?FETCH /u.test(command)) {
          assert.ok(
            session.identified,
            'An unidentified folder must not fetch messages',
          );
          assert.ok(!command.includes('BODY['), 'Body reads must use PEEK');
          if (command.includes('BODY.PEEK[]')) {
            operations.add('body');
            if (command.startsWith('UID FETCH 12 ')) {
              operations.add('oversized');
              // Send only the hostile declaration. The native parser must refuse before waiting
              // for or retaining payload; a timeout is a regression, not a passing refusal.
              socket.write(
                `* 1 FETCH (UID 12 BODY[] {${40 * 1024 * 1024 + 1}}\r\n`,
              );
            } else {
              assert.match(command, /^UID FETCH 11 /u);
              socket.write(`* 1 FETCH (UID 11 BODY[] {${raw.length}}\r\n`);
              socket.write(raw);
              socket.write(`)\r\n${tag} OK Read\r\n`);
            }
          } else {
            assertResumed(command, session);
            operations.add(
              command.includes('ENVELOPE') ? 'metadata' : 'flags-or-size',
            );
            const named = command.startsWith('UID FETCH 12 ') ? 12 : 11;
            const fields = metadataFields(command, session.large ? 511 : named);
            socket.write(
              `* ${session.large ? 500 : 1} FETCH (${fields.join(' ')})\r\n`,
            );
            ok();
          }
        } else if (command === 'LOGOUT') {
          operations.add('logout');
          socket.end(`* BYE Logging out\r\n${tag} OK Logout\r\n`);
        } else {
          // Includes non-PEEK body reads and plain EXPUNGE: reading never mutates mail.
          assert.fail(`Unexpected fixture command: ${command}`);
        }
      }
    });
  },
);
server.on('tlsClientError', (_error, socket) => {
  socket.destroy();
});
server.listen(0, '127.0.0.1', () => {
  writeFileSync(file('port'), String(server.address().port));
});
process.on('SIGTERM', () => {
  const remaining = sockets.size;
  for (const socket of sockets) {
    socket.destroy();
  }
  server.close(() => {
    assert.ok(connected >= 9, 'Real adapter sessions did not run');
    assert.equal(remaining, 0, 'Native adapter left a TLS session open');
    assert.equal(closed, connected, 'Native adapter left a TLS session open');
    assert.deepEqual([...operations].toSorted(), [
      'absent',
      'append',
      'body',
      'bounded-search-fetch',
      'copy',
      'copy-dropped',
      'copy-unmapped',
      'examine',
      'expunge',
      'flags-or-size',
      'folder-overflow',
      'gone',
      'idle',
      'idle-done',
      'large-search',
      'list',
      'logout',
      'metadata',
      'move',
      'move-dropped',
      'move-partial',
      'move-refused',
      'namespace',
      'namespace-refused',
      'oversized',
      'refused',
      'search',
      'select',
      'sent-found',
      'sent-search',
      'shared-list',
      'store-deleted',
      'store-seen',
      'store-unseen',
      'unidentified',
    ]);
    writeFileSync(
      file('result.json'),
      JSON.stringify({ connected, closed, operations: [...operations] }),
    );
  });
});
