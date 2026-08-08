import type { Server } from 'node:net';

import { createServer } from 'node:net';

import { assertLoopbackPortAvailable } from '../src/ports.ts';

describe('loopback port allocation', () => {
  it('reports a collision without disturbing the owning listener', async () => {
    expect.assertions(2);
    const { port, server } = await listenOnLoopback();
    try {
      await expect(assertLoopbackPortAvailable(port)).rejects.toMatchObject({
        code: 'EADDRINUSE',
      });
      expect(server.listening).toBe(true);
    } finally {
      await closeServer(server);
    }
  });
});

async function listenOnLoopback(): Promise<{ port: number; server: Server }> {
  const server = createServer();
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  if (address === null || typeof address === 'string') {
    server.close();
    throw new Error('The collision fixture did not expose a TCP port.');
  }
  return { port: address.port, server };
}

async function closeServer(server: Server): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => {
      if (error === undefined) {
        resolve();
      } else {
        reject(error);
      }
    });
  });
}
