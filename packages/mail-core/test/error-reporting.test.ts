import { createErrorReporting } from '@private-email/mail-core/error-reporting';

const metadata = {
  platform: 'ios',
  appVersion: '1.0',
  build: '202610181234',
  osVersion: '27.0',
  channel: 'qualification',
};
function fixture(initial: { enabled?: boolean; document?: string } = {}) {
  let state = {
    enabled: false,
    generation: 0,
    document: null as string | null,
    available: true,
    nativeAvailable: false,
    identityAvailable: true,
    metadata,
    ...initial,
  };
  const requests: Array<{
    operation: string;
    body: string;
    generation: number;
  }> = [];
  let offline = false;
  let complete = false;
  const native = {
    errorReportingRead: async () => state,
    errorReportingConsent: async (enabled: boolean, renewIdentity: boolean) => {
      state = {
        ...state,
        enabled,
        generation: state.generation + 1,
        document: enabled ? state.document : null,
      };
      if (renewIdentity) {
        complete = false;
      }
      return state;
    },
    errorReportingSave: async (generation: number, document: string) => {
      if (state.generation !== generation) {
        return { saved: false };
      }
      state.document = document;
      return { saved: true };
    },
    errorReportingRequest: async (
      operation: string,
      body: string,
      generation: number,
    ) => {
      if (
        (operation === 'capture' || operation === 'enable') &&
        (!state.enabled || generation !== state.generation)
      ) {
        throw new Error('stale');
      }
      if (offline) {
        throw new Error('offline');
      }
      requests.push({ operation, body, generation });
      const statuses: Record<string, string> = {
        capture: 'accepted',
        enable: 'enabled',
        revoke: 'disabled',
      };
      return {
        status: statuses[operation] ?? (complete ? 'complete' : 'pending'),
      };
    },
    errorReportingTakeNative: async (): Promise<{ reports: unknown[] }> => ({
      reports: [],
    }),
  };
  return {
    native,
    requests,
    state: () => state,
    offline: (value: boolean) => {
      offline = value;
    },
    complete: () => {
      complete = true;
    },
  };
}

/* oxlint-disable vitest/max-expects -- Each journey proves the full consent/deletion boundary through the public store. */
describe('installation error reporting at the protected native boundary', () => {
  it('collects only after opt-in and transmits a safe exception projection with bounded breadcrumbs', async () => {
    expect.hasAssertions();
    const host = fixture();
    const store = createErrorReporting(host.native);
    try {
      store.capture(new Error('private@example.com'));
      await store.load();
      expect(host.requests).toStrictEqual([]);
      await store.setEnabled(true);
      store.breadcrumb({ operation: 'reader', stage: 'open' });
      const error = new TypeError('Cannot convert undefined value to object', {
        cause: new Error('mail subject secret'),
      });
      error.stack =
        'TypeError: secret\n at private@example.com (index.bundle:12:9)\n at https://secret.example/path:99:8';
      store.capture(error);
      store.capture(error);
      await store.refresh();
      const capture = host.requests.find(
        (request) => request.operation === 'capture',
      );
      expect(capture).toBeDefined();
      expect(capture?.body).toContain(
        'Cannot convert undefined value to object',
      );
      expect(capture?.body).toContain('reader');
      expect(capture?.body).not.toMatch(
        /private@example|mail subject|secret.example/u,
      );
      expect(capture?.body).toContain('"line":12');
      await store.setEnabled(false);
      store.capture(error);
      await store.refresh();
      expect(host.state().enabled).toBe(false);
      expect(host.state().document).not.toContain('"id"');
      expect(
        host.requests.filter((request) => request.operation === 'capture'),
      ).toHaveLength(1);
    } finally {
      store.dispose();
    }
  });

  it('purges queued errors on deletion, stays off through offline retry and rotates only after verified completion', async () => {
    expect.hasAssertions();
    const host = fixture();
    let store = createErrorReporting(host.native);
    try {
      await store.load();
      await store.setEnabled(true);
      host.offline(true);
      store.capture(new Error('secret'));
      await store.refresh();
      expect(host.state().document).toContain('"id"');
      await store.deleteReports();
      expect(store.getSnapshot()).toMatchObject({
        kind: 'deleting',
        phase: 'offline',
      });
      expect(host.state().document).not.toContain('"id"');
      store.dispose();
      store = createErrorReporting(host.native);
      await store.load();
      expect(store.getSnapshot()).toMatchObject({ kind: 'deleting' });
      await store.setEnabled(true);
      expect(host.state().enabled).toBe(false);
      host.offline(false);
      host.complete();
      await store.retryDeletion();
      expect(store.getSnapshot()).toMatchObject({
        enabled: false,
        deletion: 'complete',
      });
      await store.setEnabled(true);
      expect(host.state().enabled).toBe(true);
    } finally {
      store.dispose();
    }
  });

  it('revokes immediately while a capture is in flight and rejects late work across relaunch', async () => {
    expect.hasAssertions();
    const host = fixture();
    const entered = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const original = host.native.errorReportingRequest;
    host.native.errorReportingRequest = async (operation, body, generation) => {
      // oxlint-disable-next-line vitest/no-conditional-in-test -- The protected transport fixture pauses only capture while revoke remains callable.
      if (operation === 'capture') {
        entered.resolve(undefined);
        await release.promise;
      }
      return original(operation, body, generation);
    };
    let store = createErrorReporting(host.native);
    try {
      await store.load();
      await store.setEnabled(true);
      store.capture(new TypeError('Invalid time value'));
      await entered.promise;
      const disabling = store.setEnabled(false);
      expect(host.state().enabled).toBe(false);
      store.capture(new Error('late callback'));
      release.resolve(undefined);
      await disabling;
      store.dispose();
      store = createErrorReporting(host.native);
      await store.load();
      expect(store.getSnapshot()).toMatchObject({ enabled: false });
      expect(
        host.requests.filter((request) => request.operation === 'capture'),
      ).toStrictEqual([]);
      expect(host.state().document).not.toContain('"id"');
    } finally {
      release.resolve(undefined);
      store.dispose();
    }
  });

  it('drops expired offline reports and bounds recent breadcrumb retention before delivery', async () => {
    expect.hasAssertions();
    const expired = {
      id: '93159d67-bd21-41d6-82d1-5cd770af1706',
      createdAt: 1,
      code: 'unhandled-js',
      name: 'Error',
      frames: [],
      causes: [],
      breadcrumbs: [],
    };
    const host = fixture({
      enabled: true,
      document: JSON.stringify({
        version: 1,
        deletion: 'idle',
        queue: [expired],
      }),
    });
    const store = createErrorReporting(host.native);
    try {
      await store.load();
      expect(
        host.requests.filter((request) => request.operation === 'capture'),
      ).toStrictEqual([]);
      for (let index = 0; index < 55; index += 1) {
        store.breadcrumb({
          operation: 'sync',
          stage: 'retry',
          elapsedMs: index,
        });
      }
      store.capture(new Error('secret'));
      await store.refresh();
      const capture = host.requests.find(
        (request) => request.operation === 'capture',
      );
      expect(capture?.body.match(/"operation":"sync"/gu)).toHaveLength(50);
      expect(capture?.body).not.toContain('"elapsedMs":0}');
      expect(capture?.body).not.toContain(expired.id);
    } finally {
      store.dispose();
    }
  });

  it('fails closed when persisted reporting data contains unknown fields', async () => {
    expect.hasAssertions();
    const host = fixture({
      enabled: true,
      document:
        '{"version":1,"queue":[],"deletion":"idle","email":"private@example.com"}',
    });
    const store = createErrorReporting(host.native);
    try {
      await store.load();
      store.capture(new Error('private@example.com'));
      await store.refresh();
      expect(store.getSnapshot()).toMatchObject({ enabled: false });
      expect(host.state().enabled).toBe(false);
      expect(
        host.requests.filter((request) => request.operation === 'capture'),
      ).toStrictEqual([]);
    } finally {
      store.dispose();
    }
  });

  it('splits maximal safe reports below the receiver byte limit', async () => {
    expect.hasAssertions();
    const host = fixture();
    const store = createErrorReporting(host.native);
    try {
      await store.load();
      await store.setEnabled(true);
      let pending: unknown[] = Array.from({ length: 10 }, (_, index) => ({
        id: `93159d67-bd21-41d6-82d1-${String(index).padStart(12, '0')}`,
        createdAt: Date.now(),
        code: 'native-crash',
        name: 'NativeCrash',
        frames: Array.from({ length: 64 }, () => ({
          kind: 'native',
          address: '0x123456789abcdef0',
          imageAddress: '0x123456789abcdef0',
          imageUuid: '93159d67-bd21-41d6-82d1-5cd770af1706',
        })),
        causes: [],
        breadcrumbs: Array.from({ length: 50 }, () => ({
          operation: 'sync',
          stage: 'complete',
          elapsedMs: 86_400_000,
          status: 503,
        })),
      }));
      host.native.errorReportingTakeNative = async () => {
        const reports = pending;
        pending = [];
        return { reports };
      };
      await store.refresh();
      const batches = host.requests.filter(
        (request) => request.operation === 'capture',
      );
      expect(batches.length).toBeGreaterThan(1);
      expect(batches.every((batch) => batch.body.length < 64 * 1024)).toBe(
        true,
      );
      expect(host.state().document).not.toContain('"id"');
    } finally {
      store.dispose();
    }
  });
});
