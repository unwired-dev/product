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
    let identified = false;
    let large = false;
    let sparse = false;
    // fallow-ignore-next-line complexity -- Exercised by the hosted native TLS test; the static JS test graph cannot see its real SwiftMail callers.
    socket.on('data', (bytes) => {
      input += bytes.toString('ascii');
      assert.ok(input.length <= 8192, 'Fixture command exceeded its bound');
      let end = -1;
      while ((end = input.indexOf('\r\n')) !== -1) {
        const line = input.slice(0, end);
        input = input.slice(end + 2);
        const separator = line.indexOf(' ');
        const tag = line.slice(0, separator);
        const command = line.slice(separator + 1);
        const ok = () => socket.write(`${tag} OK Completed\r\n`);
        if (command === 'CAPABILITY') {
          socket.write('* CAPABILITY IMAP4rev1\r\n');
          ok();
        } else if (command.startsWith('LOGIN ')) {
          if (command.includes('refused')) {
            operations.add('refused');
            socket.write(`${tag} NO [AUTHENTICATIONFAILED] Refused\r\n`);
          } else {
            assert.match(command, /synthetic-password/u);
            ok();
          }
        } else if (command.startsWith('EXAMINE ')) {
          operations.add('examine');
          identified = !command.includes('NoValidity');
          large = command.includes('Large');
          sparse = command.includes('Sparse');
          if (!identified) {
            operations.add('unidentified');
          }
          socket.write(
            `* FLAGS (\\Flagged)\r\n* ${large ? 500 : 1} EXISTS\r\n* 0 RECENT\r\n${identified ? '* OK [UIDVALIDITY 7] Stable\r\n' : ''}* OK [UIDNEXT ${uidNextOf(command)}] Next\r\n`,
          );
          socket.write(`${tag} OK [READ-ONLY] Examined\r\n`);
        } else if (command.startsWith('LIST ')) {
          operations.add('list');
          socket.write(
            // The reserved ASCII name folds case; a Unicode lookalike and an inbox role do not.
            '* LIST (\\HasNoChildren) "/" "Inbox"\r\n* LIST (\\HasNoChildren \\Archive) "/" "Archive"\r\n* LIST (\\HasNoChildren) "/" "ınbox"\r\n* LIST (\\HasNoChildren \\Inbox) "/" "Primary"\r\n',
          );
          ok();
        } else if (/^(?:UID )?FETCH /u.test(command)) {
          assert.ok(
            identified,
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
            assertResumed(command, { large, sparse });
            operations.add(
              command.includes('ENVELOPE') ? 'metadata' : 'flags-or-size',
            );
            const named = command.startsWith('UID FETCH 12 ') ? 12 : 11;
            const fields = metadataFields(command, large ? 511 : named);
            socket.write(
              `* ${large ? 500 : 1} FETCH (${fields.join(' ')})\r\n`,
            );
            ok();
          }
        } else if (command === 'LOGOUT') {
          operations.add('logout');
          socket.end(`* BYE Logging out\r\n${tag} OK Logout\r\n`);
        } else {
          // Includes SELECT, STORE and non-PEEK body reads: receive-only work must not mutate mail.
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
      'body',
      'examine',
      'flags-or-size',
      'list',
      'logout',
      'metadata',
      'oversized',
      'refused',
      'unidentified',
    ]);
    writeFileSync(
      file('result.json'),
      JSON.stringify({ connected, closed, operations: [...operations] }),
    );
  });
});
