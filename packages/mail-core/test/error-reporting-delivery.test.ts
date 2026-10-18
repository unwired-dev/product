import { createErrorReporting } from '@private-email/mail-core/error-reporting';

import { reportingFixture as fixture } from './error-reporting-fixture.ts';

/* oxlint-disable vitest/max-expects -- Each journey proves retry timing and consent boundaries through the public store. */
describe('retrying installation error reports at the protected native boundary', () => {
  it('keeps refresh, polling and new captures local until the receiver retry deadline', async () => {
    expect.hasAssertions();
    vi.useFakeTimers({ now: 1_800_000_000_000 });
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
      vi.useFakeTimers({ now: 1_800_000_000_000 });
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
        expect(
          host.requests.map((request) => request.operation),
        ).toStrictEqual(['enable', 'capture', 'enable', 'capture']);
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
    vi.useFakeTimers({ now: 1_800_000_000_000 });
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
    vi.useFakeTimers({ now: 1_800_000_000_000 });
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
});
