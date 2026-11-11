// Listens on both loopback addresses at one port. Clients try `localhost` as ::1 before
// 127.0.0.1, so a fixture bound to 127.0.0.1 alone loses any connection that another process
// listening on ::1 at the same port accepts first (#1593).
import net from 'node:net';

export const listenOnLoopback = (server, onListening) => {
  server.listen(0, '127.0.0.1', () => {
    // Hands each IPv6 connection to the same server; unref lets the fixture exit once it closes.
    const ipv6 = net.createServer((socket) => {
      server.emit('connection', socket);
    });
    ipv6.once('error', (error) => {
      if (error.code !== 'EADDRINUSE') {
        throw error;
      }
      server.close(() => {
        listenOnLoopback(server, onListening);
      });
    });
    ipv6.listen(server.address().port, '::1', () => {
      ipv6.unref();
      onListening();
    });
  });
};
