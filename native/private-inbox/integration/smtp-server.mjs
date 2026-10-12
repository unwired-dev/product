// Synthetic SMTP protocol fixture, used only by the hosted vault test runner on an owned simulator.
// It reuses the IMAP fixture's synthetic certificate, which only that simulator trusts.
/* eslint-disable node/no-sync -- Runner evidence must be written before exit. */
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import tls from 'node:tls';

const [directory] = process.argv.slice(2);
assert.ok(directory, 'Expected the runner-owned fixture directory');
const file = (name) => path.join(directory, name);
const credentials = {
  key: readFileSync(file('server.key')),
  cert: readFileSync(file('server.pem')),
  minVersion: 'TLSv1.2',
};

const operations = new Set();
const sockets = new Set();
let connected = 0;
let closed = 0;

// The user name an AUTH PLAIN response carries: authorization identity, user name, password.
const plainUser = (encoded) => {
  const [, user = '', password = ''] = Buffer.from(encoded, 'base64')
    .toString()
    .split('\0');
  return { user, password };
};

// One SMTP session. `upgrade` offers STARTTLS on a plaintext connection; `secure` is a TLS one.
// The variation follows the authenticated user name: `refused` fails AUTH, `busy` refuses MAIL
// FROM for now, `reject` refuses the message after DATA, and `drop` closes the connection once
// the message's end arrived, before any reply.
// fallow-ignore-next-line complexity -- Exercised by the hosted native TLS test; the static JS test graph cannot see its real SwiftMail callers.
const session = (initial, { upgrade, secure }) => {
  let socket = initial;
  let encrypted = secure;
  let user = '';
  let data = false;
  let message = '';
  let input = '';
  connected += 1;
  sockets.add(initial);
  initial.on('close', () => {
    sockets.delete(initial);
    closed += 1;
  });
  const write = (line) => socket.write(`${line}\r\n`);
  const interruptions = new Map([
    ['drop-mail', 'MAIL FROM:'],
    ['drop-rcpt', 'RCPT TO:'],
    ['drop-data', 'DATA'],
  ]);
  const interrupt = (command) => {
    const prefix = interruptions.get(user);
    if (prefix === undefined || !command.startsWith(prefix)) {
      return false;
    }
    operations.add(user);
    socket.destroy();
    return true;
  };
  // fallow-ignore-next-line complexity -- Exercised by the hosted native TLS test; the static JS test graph cannot see its real SwiftMail callers.
  const answer = (line) => {
    const command = line.toUpperCase();
    if (interrupt(command)) {
      // Closed before any message content could be accepted.
    } else if (command.startsWith('EHLO ')) {
      // Authentication is offered only inside TLS.
      write('250-localhost');
      write(encrypted ? '250-AUTH PLAIN' : '250-PIPELINING');
      if (upgrade && !encrypted) {
        write('250-STARTTLS');
      }
      write('250 SIZE 1000000');
    } else if (command === 'STARTTLS') {
      assert.ok(upgrade && !encrypted, 'STARTTLS only where offered');
      operations.add('starttls');
      write('220 Ready to start TLS');
      socket.removeAllListeners('data');
      socket = new tls.TLSSocket(socket, { isServer: true, ...credentials });
      socket.on('error', () => {
        socket.destroy();
      });
      encrypted = true;
      listen();
    } else if (command.startsWith('AUTH PLAIN ')) {
      assert.ok(encrypted, 'A password is sent only inside TLS');
      const login = plainUser(line.slice('AUTH PLAIN '.length));
      if (login.user === 'refused' || login.password !== 'synthetic-password') {
        operations.add('smtp-refused');
        write('535 5.7.8 Authentication failed');
      } else {
        ({ user } = login);
        operations.add(upgrade ? 'auth-starttls' : 'auth-tls');
        write('235 2.7.0 Authenticated');
      }
    } else if (command.startsWith('MAIL FROM:')) {
      assert.ok(user, 'MAIL FROM follows authentication');
      if (user === 'busy') {
        operations.add('busy');
        write('451 4.3.2 Try again later');
      } else {
        assert.match(line, /^MAIL FROM:<alex@example\.invalid>/iu);
        write('250 2.1.0 OK');
      }
    } else if (command.startsWith('RCPT TO:')) {
      assert.match(line, /^RCPT TO:<(?:sam|jo)@example\.invalid>$/iu);
      operations.add('rcpt');
      if (user === 'reject-recipient' && command.includes('JO@')) {
        operations.add('recipient-rejected');
        write('550 5.1.1 Recipient refused');
      } else {
        write('250 2.1.5 OK');
      }
    } else if (command === 'DATA') {
      data = true;
      message = '';
      write('354 End data with <CR><LF>.<CR><LF>');
    } else if (command === 'RSET') {
      write('250 2.0.0 OK');
    } else if (command === 'QUIT') {
      write('221 2.0.0 Bye');
      socket.end();
    } else {
      assert.fail(`Unexpected SMTP command: ${line}`);
    }
  };
  // fallow-ignore-next-line complexity -- Exercised by the hosted native TLS test; the static JS test graph cannot see its real SwiftMail callers.
  const finish = () => {
    data = false;
    assert.ok(!/^Bcc:/imu.test(message), 'Native code removes Bcc');
    if (user === 'drop') {
      operations.add('dropped');
      socket.destroy();
    } else if (user === 'reject') {
      operations.add('rejected');
      write('554 5.7.1 Message refused');
    } else {
      operations.add('accepted');
      write('250 2.0.0 Queued');
    }
  };
  function listen() {
    // fallow-ignore-next-line complexity -- The hosted SMTP test executes every submission phase; static JS coverage cannot see the Swift caller.
    socket.on('data', (bytes) => {
      input += bytes.toString('ascii');
      assert.ok(input.length <= 65_536, 'Fixture input exceeded its bound');
      let end = -1;
      while ((end = input.indexOf('\r\n')) !== -1) {
        const line = input.slice(0, end);
        input = input.slice(end + 2);
        if (!data) {
          answer(line);
        } else if (line === '.') {
          finish();
        } else if (user === 'drop-body') {
          operations.add('drop-body');
          socket.destroy();
          return;
        } else {
          message += `${line}\r\n`;
        }
      }
    });
  }
  initial.on('error', () => {
    initial.destroy();
  });
  listen();
  write('220 localhost Controlled SMTP ready');
};

const servers = [
  tls.createServer(credentials, (socket) => {
    session(socket, { upgrade: false, secure: true });
  }),
  net.createServer((socket) => {
    session(socket, { upgrade: true, secure: false });
  }),
  // Offers no STARTTLS: a client that requires it must leave before sending a password.
  net.createServer((socket) => {
    operations.add('plaintext');
    session(socket, { upgrade: false, secure: false });
  }),
];
servers[0].on('tlsClientError', (_error, socket) => {
  socket.destroy();
});
let listening = 0;
const didListen = () => {
  listening += 1;
  if (listening === servers.length) {
    writeFileSync(
      file('smtp-ports'),
      servers.map((each) => each.address().port).join(','),
    );
  }
};
for (const server of servers) {
  server.listen(0, '127.0.0.1', didListen);
}
process.on('SIGTERM', () => {
  const remaining = sockets.size;
  for (const socket of sockets) {
    socket.destroy();
  }
  for (const server of servers) {
    server.close();
  }
  assert.ok(connected >= 7, 'Real SMTP sessions did not run');
  assert.equal(remaining, 0, 'Native adapter left an SMTP session open');
  assert.deepEqual([...operations].toSorted(), [
    'accepted',
    'auth-starttls',
    'auth-tls',
    'busy',
    'drop-body',
    'drop-data',
    'drop-mail',
    'drop-rcpt',
    'dropped',
    'plaintext',
    'rcpt',
    'recipient-rejected',
    'rejected',
    'smtp-refused',
    'starttls',
  ]);
  writeFileSync(
    file('smtp-result.json'),
    JSON.stringify({ connected, closed, operations: [...operations] }),
  );
});
