import { createErrorReporting } from '@private-email/mail-core/error-reporting';

import { reportingFixture as fixture } from './error-reporting-fixture.ts';

// Keep Effect's scheduler real while controlling wall time and polling delays.
/* oxlint-disable vitest/max-expects -- Each journey proves retry timing and consent boundaries through the public store. */
describe('retrying installation error reports at the protected native boundary', () => {
  it('keeps refresh, polling and new captures local until the receiver retry deadline', async () => {
    expect.hasAssertions();
    vi.useFakeTimers({
      now: 1_800_000_000_000,
      toFake: ['Date', 'setTimeout', 'clearTimeout'],
    });
    const expiringId = '93159d67-bd21-41d6-82d1-5cd770af1706';
    const host = fixture({
      enabled: true,
      document: JSON.stringify({
        version: 1,
        deletion: 'idle',
        queue: [
          {
            id: expiringId,
            createdAt: 1_800_000_000_000 - 86_400_000 + 30_000,
            code: 'unhandled-js',
            name: 'Error',
            frames: [],
            causes: [],
            breadcrumbs: [],
          },
        ],
      }),
    });
    const original = host.native.errorReportingRequest;
    vi.spyOn(host.native, 'errorReportingRequest')
      .mockImplementationOnce(original)
      .mockImplementationOnce(async (...args) => {
        await original(...args);
        return { status: 'retry', retryAfterMs: 60_000 };
      })
      .mockImplementationOnce(original)
      .mockImplementationOnce(async (...args) => {
        await original(...args);
        return { status: 'accepted', retryAfterMs: 0 };
      });
    const store = createErrorReporting(host.native);
    try {
      await store.load();
      store.capture(new Error('private@example.com'));
      await store.refresh();
      expect(host.requests.map((request) => request.operation)).toStrictEqual([
        'enable',
        'capture',
      ]);
      store.capture(new TypeError('mail subject secret'));
      await store.refresh();
      await vi.advanceTimersByTimeAsync(30_000);
      expect(host.requests).toHaveLength(2);
      expect(host.state().document).toContain(expiringId);
      await vi.advanceTimersByTimeAsync(29_999);
      await store.refresh();
      expect(host.requests).toHaveLength(2);
      expect(host.state().document?.match(/"id":/gu)).toHaveLength(2);
      expect(host.state().document).not.toMatch(
        /private@example|mail subject/u,
      );
      await vi.advanceTimersByTimeAsync(1);
      await store.refresh();
      expect(host.requests.map((request) => request.operation)).toStrictEqual([
        'enable',
        'capture',
        'enable',
        'capture',
      ]);
      expect(host.requests.at(-1)?.body.match(/"id":/gu)).toHaveLength(2);
      expect(host.requests.at(-1)?.body).not.toContain(expiringId);
      expect(host.requests.at(-1)?.body).not.toMatch(
        /private@example|mail subject/u,
      );
      expect(host.state().document).not.toContain('"id"');
      await store.refresh();
      expect(host.requests).toHaveLength(4);
    } finally {
      store.dispose();
      vi.useRealTimers();
      vi.restoreAllMocks();
    }
  });

  it.each([
    { status: 'retry' },
    { status: 'retry', retryAfterMs: 0 },
    { status: 'retry', retryAfterMs: -1 },
    { status: 'retry', retryAfterMs: 0.5 },
    { status: 'retry', retryAfterMs: 86_400_001 },
    { status: 'retry', retryAfterMs: Infinity },
    { status: 'retry', retryAfterMs: '60000' },
    { status: 'accepted', retryAfterMs: 'invalid' },
  ])(
    'uses the polling interval for an unusable retry delay: %j',
    async (reply) => {
      expect.hasAssertions();
      vi.useFakeTimers({
        now: 1_800_000_000_000,
        toFake: ['Date', 'setTimeout', 'clearTimeout'],
      });
      const host = fixture({ enabled: true });
      const original = host.native.errorReportingRequest;
      vi.spyOn(host.native, 'errorReportingRequest')
        .mockImplementationOnce(original)
        .mockImplementationOnce(async (...args) => {
          await original(...args);
          return reply;
        });
      const store = createErrorReporting(host.native);
      try {
        await store.load();
        store.capture(new Error('private@example.com'));
        await store.refresh();
        await vi.advanceTimersByTimeAsync(29_999);
        await store.refresh();
        expect(host.requests).toHaveLength(2);
        await vi.advanceTimersByTimeAsync(1);
        await store.refresh();
        const sent = host.requests.map((request) => request.operation);
        expect(sent).toStrictEqual(['enable', 'capture', 'enable', 'capture']);
        expect(host.state().document).not.toContain('"id"');
      } finally {
        store.dispose();
        vi.useRealTimers();
        vi.restoreAllMocks();
      }
    },
  );

  it('deletes during backoff and starts renewed consent without the old deadline', async () => {
    expect.hasAssertions();
    vi.useFakeTimers({
      now: 1_800_000_000_000,
      toFake: ['Date', 'setTimeout', 'clearTimeout'],
    });
    const host = fixture({ enabled: true });
    const original = host.native.errorReportingRequest;
    vi.spyOn(host.native, 'errorReportingRequest')
      .mockImplementationOnce(original)
      .mockImplementationOnce(async (...args) => {
        await original(...args);
        return { status: 'retry', retryAfterMs: 60_000 };
      });
    const store = createErrorReporting(host.native);
    try {
      await store.load();
      store.capture(new Error('deleted secret'));
      await store.refresh();
      host.complete();
      await store.deleteReports();
      expect(host.state().enabled).toBe(false);
      expect(store.getSnapshot()).toMatchObject({ deletion: 'complete' });
      await store.setEnabled(true);
      store.capture(new TypeError('Invalid time value'));
      await store.refresh();
      expect(host.requests.map((request) => request.operation)).toStrictEqual([
        'enable',
        'capture',
        'revoke',
        'delete',
        'enable',
        'capture',
      ]);
      expect(host.requests.at(-1)?.body.match(/"id":/gu)).toHaveLength(1);
      expect(host.requests.at(-1)?.body).toContain('Invalid time value');
      expect(host.state().document).not.toContain('"id"');
    } finally {
      store.dispose();
      vi.useRealTimers();
      vi.restoreAllMocks();
    }
  });

  it('does not restore an in-flight retry delay after withdrawal and re-enabling', async () => {
    expect.hasAssertions();
    vi.useFakeTimers({
      now: 1_800_000_000_000,
      toFake: ['Date', 'setTimeout', 'clearTimeout'],
    });
    const host = fixture({ enabled: true });
    const entered = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const original = host.native.errorReportingRequest;
    vi.spyOn(host.native, 'errorReportingRequest')
      .mockImplementationOnce(original)
      .mockImplementationOnce(async (...args) => {
        await original(...args);
        entered.resolve(undefined);
        await release.promise;
        return { status: 'retry', retryAfterMs: 60_000 };
      });
    const store = createErrorReporting(host.native);
    try {
      await store.load();
      store.capture(new Error('withdrawn secret'));
      await entered.promise;
      const withdrawal = store.setEnabled(false);
      expect(store.getSnapshot()).toMatchObject({ enabled: false });
      expect(host.state().enabled).toBe(false);
      release.resolve(undefined);
      await withdrawal;
      await store.setEnabled(true);
      store.capture(new TypeError('Invalid time value'));
      await store.refresh();
      expect(host.requests.map((request) => request.operation)).toStrictEqual([
        'enable',
        'capture',
        'revoke',
        'enable',
        'capture',
      ]);
      expect(host.requests.at(-1)?.body.match(/"id":/gu)).toHaveLength(1);
      expect(host.requests.at(-1)?.body).toContain('Invalid time value');
      expect(host.requests.at(-1)?.body).not.toContain('withdrawn secret');
      expect(host.state().document).not.toContain('"id"');
    } finally {
      release.resolve(undefined);
      store.dispose();
      vi.useRealTimers();
      vi.restoreAllMocks();
    }
  });

  describe.each([
    {
      operation: 'enable',
      failedAttempts: 1,
      failNext: (
        native: Readonly<ReturnType<typeof fixture>['native']>,
        failure: () => Promise<never>,
      ) =>
        vi
          .spyOn(native, 'errorReportingRequest')
          .mockImplementationOnce(failure),
    },
    {
      operation: 'capture',
      failedAttempts: 2,
      failNext: (
        native: Readonly<ReturnType<typeof fixture>['native']>,
        failure: () => Promise<never>,
      ) => {
        const original = native.errorReportingRequest;
        return vi
          .spyOn(native, 'errorReportingRequest')
          .mockImplementationOnce(original)
          .mockImplementationOnce(failure);
      },
    },
  ])('$operation transport failures', ({ failNext, failedAttempts }) => {
    it('maintains the local queue until the fallback deadline and clears it after acceptance', async () => {
      expect.hasAssertions();
      vi.useFakeTimers({
        now: 1_800_000_000_000,
        toFake: ['Date', 'setTimeout', 'clearTimeout'],
      });
      const expiringId = '93159d67-bd21-41d6-82d1-5cd770af1706';
      const host = fixture({
        enabled: true,
        document: JSON.stringify({
          version: 1,
          deletion: 'idle',
          queue: [
            {
              id: expiringId,
              createdAt: 1_800_000_000_000 - 86_400_000 + 10_000,
              code: 'unhandled-js',
              name: 'Error',
              frames: [],
              causes: [],
              breadcrumbs: [],
            },
          ],
        }),
      });
      const attempts = failNext(host.native, async () => {
        throw Object.assign(new Error('private transport secret'), {
          code: 'offline',
        });
      });
      const drain = vi.spyOn(host.native, 'errorReportingTakeNative');
      const store = createErrorReporting(host.native);
      try {
        await store.load();
        expect(host.state().document).toContain(expiringId);
        await vi.advanceTimersByTimeAsync(10_001);
        drain.mockResolvedValueOnce({
          reports: Array.from({ length: 31 }, (_, index) => ({
            id: `93159d67-bd21-41d6-82d1-${String(index).padStart(12, '0')}`,
            createdAt: 1_800_000_010_001,
            code: 'native-crash',
            name: 'Error',
            frames: [],
            causes: [],
            breadcrumbs: [],
          })),
        });
        store.capture(new Error('private@example.com'));
        await store.refresh();
        store.capture(new TypeError('mail subject secret'));
        await store.refresh();
        await vi.advanceTimersByTimeAsync(19_998);
        await store.refresh();
        expect(attempts).toHaveBeenCalledTimes(failedAttempts);
        expect(host.state().document?.match(/"id":/gu)).toHaveLength(32);
        expect(host.state().document).not.toMatch(
          /93159d67-bd21-41d6-82d1-5cd770af1706|private@example|mail subject|private transport/u,
        );
        await vi.advanceTimersByTimeAsync(1);
        await store.refresh();
        expect(host.state().document).not.toContain('"id"');
        expect(attempts).toHaveBeenCalledTimes(failedAttempts + 5);
        store.capture(new TypeError('Invalid time value'));
        await store.refresh();
        expect(
          attempts.mock.calls.slice(-2).map(([operation]) => operation),
        ).toStrictEqual(['enable', 'capture']);
        expect(host.requests.at(-1)?.body).toContain('Invalid time value');
        expect(host.state().document).not.toContain('"id"');
      } finally {
        store.dispose();
        vi.useRealTimers();
        vi.restoreAllMocks();
      }
    });

    it.each([
      {
        action: 'disable',
        withdraw: (store: ReturnType<typeof createErrorReporting>) =>
          store.setEnabled(false),
        snapshot: { kind: 'ready', enabled: false, deletion: 'idle' },
      },
      {
        action: 'delete',
        withdraw: (store: ReturnType<typeof createErrorReporting>) =>
          store.deleteReports(),
        snapshot: { kind: 'ready', enabled: false, deletion: 'complete' },
      },
    ])(
      'allows $action during transport backoff',
      async ({ withdraw, snapshot }) => {
        expect.hasAssertions();
        vi.useFakeTimers({
          now: 1_800_000_000_000,
          toFake: ['Date', 'setTimeout', 'clearTimeout'],
        });
        const host = fixture({ enabled: true });
        failNext(host.native, async () => {
          throw new Error('private transport secret');
        });
        const store = createErrorReporting(host.native);
        try {
          await store.load();
          store.capture(new Error('withdrawn secret'));
          await store.refresh();
          host.complete();
          await withdraw(store);
          expect(store.getSnapshot()).toStrictEqual(snapshot);
          expect(host.state().document).not.toContain('"id"');
          await store.setEnabled(true);
          store.capture(new TypeError('Invalid time value'));
          await store.refresh();
          expect(host.requests.at(-1)?.operation).toBe('capture');
          expect(host.requests.at(-1)?.body).toContain('Invalid time value');
          expect(host.requests.at(-1)?.body).not.toContain('withdrawn secret');
        } finally {
          store.dispose();
          vi.useRealTimers();
          vi.restoreAllMocks();
        }
      },
    );

    it('does not restore a stale failure deadline after renewed consent acknowledges', async () => {
      expect.hasAssertions();
      vi.useFakeTimers({
        now: 1_800_000_000_000,
        toFake: ['Date', 'setTimeout', 'clearTimeout'],
      });
      const host = fixture({ enabled: true });
      const entered = Promise.withResolvers<undefined>();
      const release = Promise.withResolvers<undefined>();
      failNext(host.native, async () => {
        entered.resolve(undefined);
        await release.promise;
        throw new Error('withdrawn transport secret');
      });
      const store = createErrorReporting(host.native);
      try {
        await store.load();
        store.capture(new Error('withdrawn secret'));
        await entered.promise;
        const withdrawal = store.setEnabled(false);
        await vi.waitUntil(() => store.getSnapshot().kind === 'ready');
        const renewal = store.setEnabled(true);
        await vi.waitUntil(() => store.getSnapshot().kind === 'ready');
        expect(store.getSnapshot()).toMatchObject({ enabled: true });
        release.resolve(undefined);
        await withdrawal;
        await renewal;
        store.capture(new TypeError('Invalid time value'));
        await store.refresh();
        expect(host.requests.at(-1)?.operation).toBe('capture');
        expect(host.requests.at(-1)?.body).toContain('Invalid time value');
        expect(host.requests.at(-1)?.body).not.toContain('withdrawn secret');
        expect(host.state().document).not.toContain('"id"');
      } finally {
        release.resolve(undefined);
        store.dispose();
        vi.useRealTimers();
        vi.restoreAllMocks();
      }
    });
  });
});
