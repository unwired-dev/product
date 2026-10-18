import { createErrorReporting } from '@private-email/mail-core/error-reporting';

import { reportingFixture as fixture } from './error-reporting-fixture.ts';

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

  it('ignores stale deletion retry actions after consent or identity changes', async () => {
    expect.hasAssertions();
    const host = fixture();
    const store = createErrorReporting(host.native);
    try {
      await store.load();
      await store.setEnabled(true);
      await store.retryDeletion();
      expect(store.getSnapshot()).toMatchObject({
        enabled: true,
        deletion: 'idle',
      });
      expect(
        host.requests.filter((request) => request.operation === 'delete'),
      ).toStrictEqual([]);
      await store.deleteReports();
      host.complete();
      await store.retryDeletion();
      await store.setEnabled(true);
      const requests = host.requests.length;
      await store.retryDeletion();
      expect(host.requests).toHaveLength(requests);
      expect(store.getSnapshot()).toMatchObject({
        enabled: true,
        deletion: 'idle',
      });
    } finally {
      store.dispose();
    }
  });

  it('ignores deletion completion after a newer consent revision', async () => {
    expect.hasAssertions();
    const host = fixture();
    const store = createErrorReporting(host.native);
    const entered = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    try {
      await store.load();
      await store.setEnabled(true);
      vi.spyOn(host.native, 'errorReportingRequest')
        .mockImplementationOnce(host.native.errorReportingRequest)
        .mockImplementationOnce(async () => {
          entered.resolve(undefined);
          await release.promise;
          return { status: 'complete' };
        });
      const deleting = store.deleteReports();
      await entered.promise;
      const withdrawing = store.setEnabled(false);
      release.resolve(undefined);
      await Promise.all([deleting, withdrawing]);
      expect(store.getSnapshot()).toMatchObject({
        kind: 'deleting',
        phase: 'pending',
      });
      expect(host.state().enabled).toBe(false);
      expect(host.state().document).not.toContain('complete');
    } finally {
      release.resolve(undefined);
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

  it('keeps server deletion failures retryable without describing them as offline', async () => {
    expect.hasAssertions();
    const host = fixture();
    const store = createErrorReporting(host.native);
    try {
      await store.load();
      await store.setEnabled(true);
      const original = host.native.errorReportingRequest;
      host.native.errorReportingRequest = async (
        operation,
        body,
        generation,
      ) =>
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Only the external deletion request fails in this recovery journey.
        operation === 'delete'
          ? { status: 'retry' }
          : original(operation, body, generation);
      await store.deleteReports();
      expect(store.getSnapshot()).toMatchObject({
        kind: 'deleting',
        phase: 'failed',
      });
      store.dispose();
      const reopened = createErrorReporting(host.native);
      host.native.errorReportingRequest = original;
      host.complete();
      await reopened.load();
      expect(reopened.getSnapshot()).toMatchObject({
        enabled: false,
        deletion: 'complete',
      });
      reopened.dispose();
    } finally {
      store.dispose();
    }
  });

  it('blocks re-enabling as soon as deletion starts while withdrawal is in flight', async () => {
    expect.hasAssertions();
    const host = fixture();
    const entered = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const original = host.native.errorReportingRequest;
    host.native.errorReportingRequest = async (operation, body, generation) => {
      // oxlint-disable-next-line vitest/no-conditional-in-test -- Hold only the withdrawal to exercise the public deletion race.
      if (operation === 'revoke') {
        entered.resolve(undefined);
        await release.promise;
      }
      return original(operation, body, generation);
    };
    const store = createErrorReporting(host.native);
    try {
      await store.load();
      await store.setEnabled(true);
      const deleting = store.deleteReports();
      await entered.promise;
      expect(store.getSnapshot()).toMatchObject({ kind: 'deleting' });
      await store.setEnabled(true);
      expect(host.state().enabled).toBe(false);
      release.resolve(undefined);
      await deleting;
      expect(host.state().enabled).toBe(false);
    } finally {
      release.resolve(undefined);
      store.dispose();
    }
  });

  it('refuses an enable that reaches native after a later withdrawal', async () => {
    expect.hasAssertions();
    const host = fixture();
    const entered = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const original = host.native.errorReportingConsent;
    const store = createErrorReporting(host.native);
    try {
      await store.load();
      host.native.errorReportingConsent = async (...args) => {
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Reorder only the external enable, so a later withdrawal reaches native first.
        if (args[0]) {
          entered.resolve(undefined);
          await release.promise;
        }
        return original(...args);
      };
      const enabling = store.setEnabled(true);
      await entered.promise;
      await store.setEnabled(false);
      release.resolve(undefined);
      await enabling;
      expect(host.state().enabled).toBe(false);
      expect(store.getSnapshot()).toMatchObject({ enabled: false });
    } finally {
      release.resolve(undefined);
      store.dispose();
    }
  });

  it('keeps deletion intent when an older capture save is refused after withdrawal', async () => {
    expect.hasAssertions();
    const host = fixture();
    const saving = Promise.withResolvers<undefined>();
    const releaseSave = Promise.withResolvers<undefined>();
    const revoking = Promise.withResolvers<undefined>();
    const releaseRevoke = Promise.withResolvers<undefined>();
    const originalSave = host.native.errorReportingSave;
    const originalRequest = host.native.errorReportingRequest;
    const store = createErrorReporting(host.native);
    try {
      await store.load();
      await store.setEnabled(true);
      host.native.errorReportingSave = async (generation, document) => {
        saving.resolve(undefined);
        await releaseSave.promise;
        return originalSave(generation, document);
      };
      host.native.errorReportingRequest = async (
        operation,
        body,
        generation,
      ) => {
        // oxlint-disable-next-line vitest/no-conditional-in-test -- The external withdrawal remains held while the stale save settles.
        if (operation === 'revoke') {
          revoking.resolve(undefined);
          await releaseRevoke.promise;
        }
        return originalRequest(operation, body, generation);
      };
      store.capture(new Error('synthetic failure'));
      await saving.promise;
      const deleting = store.deleteReports();
      releaseSave.resolve(undefined);
      await revoking.promise;
      expect(store.getSnapshot()).toMatchObject({ kind: 'deleting' });
      await store.setEnabled(true);
      expect(host.state().enabled).toBe(false);
      releaseRevoke.resolve(undefined);
      await deleting;
      expect(store.getSnapshot()).toMatchObject({ kind: 'deleting' });
    } finally {
      releaseSave.resolve(undefined);
      releaseRevoke.resolve(undefined);
      store.dispose();
    }
  });

  it('publishes native consent before a slow delivery and ignores duplicate enable', async () => {
    expect.hasAssertions();
    const host = fixture();
    const store = createErrorReporting(host.native);
    const entered = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const original = host.native.errorReportingRequest;
    try {
      await store.load();
      vi.spyOn(host.native, 'errorReportingRequest').mockImplementationOnce(
        async (operation, body, generation) => {
          entered.resolve(undefined);
          await release.promise;
          return original(operation, body, generation);
        },
      );
      const enabling = store.setEnabled(true);
      expect(store.getSnapshot()).toMatchObject({
        kind: 'saving',
        enabled: false,
      });
      await entered.promise;
      expect(store.getSnapshot()).toMatchObject({
        kind: 'ready',
        enabled: true,
      });
      const { generation } = host.state();
      await store.setEnabled(true);
      expect(host.state().generation).toBe(generation);
      release.resolve(undefined);
      await enabling;
    } finally {
      release.resolve(undefined);
      store.dispose();
    }
  });

  it('retains bundle coordinates when the packaged runtime omits named captures', async () => {
    expect.hasAssertions();
    const host = fixture();
    const store = createErrorReporting(host.native);
    const nativeExec = RegExp.prototype.exec;
    try {
      await store.load();
      await store.setEnabled(true);
      const spy = vi
        .spyOn(RegExp.prototype, 'exec')
        .mockImplementation(function (this: RegExp, text: string) {
          const result = nativeExec.call(this, text);
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Match the host result while preserving ordinary nonmatches.
          if (result !== null) {
            delete result.groups;
          }
          return result;
        });
      const error = new Error('private body');
      error.stack = 'Error: private body\n at read (index.bundle:12:9)';
      store.capture(error);
      spy.mockRestore();
      await store.refresh();
      const capture = host.requests.find(
        (request) => request.operation === 'capture',
      );
      expect(capture?.body).toContain('"line":12,"column":9');
      expect(capture?.body).not.toContain('private body');
    } finally {
      vi.restoreAllMocks();
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
