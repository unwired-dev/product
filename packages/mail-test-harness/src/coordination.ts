import type { Server } from 'node:http';

import { createServer } from 'node:http';

export interface MailTestCoordinator {
  close: () => Promise<void>;
  url: string;
  verifyCompleted: () => Promise<void>;
}

export async function startMailTestCoordinator(options: {
  onInitialSynchronization: () => Promise<void>;
  runId: string;
  signal?: AbortSignal;
}): Promise<MailTestCoordinator> {
  let phase: 'completed' | 'failed' | 'idle' | 'injecting' = 'idle';
  let failure: unknown = undefined;
  const pathname = `/incremental-arrival/${options.runId}/initial-synchronized`;
  // oxlint-disable-next-line typescript/no-misused-promises, typescript/strict-void-return -- The HTTP listener owns and completes the request-scoped asynchronous injection before responding.
  const server = createServer(async (request, response) => {
    request.resume();
    if (request.method !== 'POST' || request.url !== pathname) {
      response.writeHead(404).end();
      return;
    }
    if (phase !== 'idle') {
      response.writeHead(409).end();
      return;
    }
    phase = 'injecting';
    try {
      await options.onInitialSynchronization();
      phase = 'completed';
      response.writeHead(204).end();
    } catch (error) {
      failure = error;
      phase = 'failed';
      response.writeHead(500).end();
    }
  });
  const onAbort = (): void => {
    server.closeAllConnections();
    server.close();
  };
  options.signal?.addEventListener('abort', onAbort, { once: true });
  try {
    await listen(server);
  } catch (error) {
    options.signal?.removeEventListener('abort', onAbort);
    throw error;
  }
  const address = server.address();
  if (address === null || typeof address === 'string') {
    await close(server);
    options.signal?.removeEventListener('abort', onAbort);
    throw new Error('Mail-test coordination server did not expose a port.');
  }
  return {
    close: async () => {
      options.signal?.removeEventListener('abort', onAbort);
      await close(server);
    },
    url: `http://127.0.0.1:${String(address.port)}${pathname}`,
    verifyCompleted: async () => {
      if (phase === 'completed') {
        return;
      }
      if (phase === 'failed') {
        throw new Error(
          `Incremental-arrival injection or provider observation failed: ${String(failure)}`,
        );
      }
      if (phase === 'injecting') {
        throw new Error(
          'Incremental-arrival injection was still running when the client scenario finished.',
        );
      }
      throw new Error(
        'Incremental-arrival injection did not start after initial synchronization.',
      );
    },
  };
}

async function listen(server: Server): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      server.off('error', reject);
      resolve();
    });
  });
}

async function close(server: Server): Promise<void> {
  if (!server.listening) {
    return;
  }
  server.closeAllConnections();
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
