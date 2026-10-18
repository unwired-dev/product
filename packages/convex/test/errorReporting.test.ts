/// <reference types="vite/client" />

import { createReportingTest } from '@private-email/convex/testing';
import * as Predicate from 'effect/Predicate';

const modules = import.meta.glob('../convex/**/*.ts');
const identity = {
  installationId: '12345678-1234-4123-8123-123456789abc',
  credential: 'a'.repeat(64),
  generation: 1,
};
const metadata = {
  platform: 'ios',
  appVersion: '1.0.0',
  build: '1',
  osVersion: '27.0',
  channel: 'qualification',
};
const report = () => ({
  id: 'abcdef12-1234-4123-8123-123456789abc',
  createdAt: Date.now(),
  code: 'unhandled-js',
  name: 'TypeError',
  message: 'Cannot convert undefined value to object',
  frames: [{ kind: 'javascript', line: 42, column: 5 }],
  causes: [],
  breadcrumbs: [{ operation: 'sync', stage: 'failed', status: 503 }],
});

const nativeReport = () => ({
  ...report(),
  id: '87654321-4321-4321-8321-abcdef123456',
  code: 'native-crash',
  name: 'NativeCrash',
  message: 'Synthetic native crash',
  frames: [
    {
      kind: 'native',
      address: '0x1234',
      imageAddress: '0x1000',
      imageUuid: 'abcdef12-1234-4123-8123-123456789abc',
    },
  ],
});

async function status(
  t: ReturnType<typeof createReportingTest>,
  operation: string,
  fields: object = {},
) {
  const result = await post(t, operation, fields);
  return result.status;
}
async function body(
  t: ReturnType<typeof createReportingTest>,
  operation: string,
  fields: object = {},
) {
  const result = await post(t, operation, fields);
  return result.json();
}

function post(
  t: ReturnType<typeof createReportingTest>,
  operation: string,
  fields: object = {},
) {
  return t.backend.fetch(`/api/error-reporting/${operation}`, {
    method: 'POST',
    body: JSON.stringify({ ...identity, ...fields }),
    headers: { 'content-type': 'application/json' },
  });
}

function configure() {
  vi.stubEnv('POSTHOG_PROJECT_KEY', 'phc_synthetic');
  vi.stubEnv('POSTHOG_PROJECT_ID', '123');
  vi.stubEnv('POSTHOG_PERSON_API_KEY', 'phx_synthetic');
}

const personId = '11111111-1111-4111-8111-111111111111';
function provider(
  state: {
    visible: boolean;
    deleted: boolean;
    verified: boolean;
    failDelete: boolean;
  },
  outbound: string[],
) {
  return async (input: string, init?: RequestInit) => {
    outbound.push(input);
    if (input.includes('deletion_status')) {
      return Response.json({
        results: state.deleted
          ? [
              {
                person_uuid: personId,
                status: state.verified ? 'completed' : 'pending',
                delete_verified_at: state.verified
                  ? '2026-10-18T12:00:00Z'
                  : null,
              },
            ]
          : [],
      });
    }
    if (init?.method === 'DELETE') {
      if (state.failDelete) {
        state.failDelete = false;
        return new Response(null, { status: 503 });
      }
      state.deleted = true;
      return new Response(null, { status: 202 });
    }
    if (input.includes('/persons/')) {
      return Response.json({
        results:
          state.visible && !state.deleted
            ? [
                {
                  id: personId,
                  distinct_ids: [identity.installationId],
                  properties: {},
                },
              ]
            : [],
        next: null,
      });
    }
    return Response.json({ status: 1 });
  };
}
function captureProvider(outbound: string[]) {
  return async (_url: string, init?: RequestInit) => {
    outbound.push(Predicate.isString(init?.body) ? init.body : '');
    return Response.json({ status: 1 });
  };
}

function delayedCapture(
  downstream: ReturnType<typeof provider>,
  entered: PromiseWithResolvers<undefined>,
  delivered: PromiseWithResolvers<Response>,
) {
  return (input: string, init?: RequestInit) => {
    if (input.includes('/batch/')) {
      entered.resolve(undefined);
      return delivered.promise;
    }
    return downstream(input, init);
  };
}

/* oxlint-disable vitest/max-expects -- Each HTTP journey proves a complete privacy or consent transition. */
describe('anonymous error reporting HTTP capability', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Restore isolated provider and environment seams after each HTTP journey.
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it('fences stale consent and rejects a stolen installation identifier', async () => {
    expect.hasAssertions();
    configure();
    const t = createReportingTest(modules);
    await expect(status(t, 'enable')).resolves.toBe(200);
    await expect(
      status(t, 'capture', {
        credential: 'b'.repeat(64),
        reports: [report()],
        metadata,
      }),
    ).resolves.toBe(403);
    await expect(body(t, 'revoke', { generation: 2 })).resolves.toStrictEqual({
      status: 'disabled',
    });
    await expect(status(t, 'enable')).resolves.toBe(409);
    await expect(
      status(t, 'capture', { reports: [report()], metadata }),
    ).resolves.toBe(409);
    await expect(body(t, 'enable', { generation: 3 })).resolves.toStrictEqual({
      status: 'enabled',
    });
  });

  it('remembers revocation before an offline first enable arrives and never reuses a deleted identity', async () => {
    expect.hasAssertions();
    const t = createReportingTest(modules);
    await expect(body(t, 'revoke', { generation: 2 })).resolves.toStrictEqual({
      status: 'disabled',
    });
    await expect(status(t, 'enable')).resolves.toBe(409);
    await expect(body(t, 'delete', { generation: 3 })).resolves.toStrictEqual({
      status: 'complete',
    });
    await expect(status(t, 'enable', { generation: 4 })).resolves.toBe(409);
  });

  it('rejects sensitive and unbounded data before vendor delivery; sends only approved exception fields', async () => {
    expect.hasAssertions();
    configure();
    const outbound: string[] = [];
    vi.stubGlobal('fetch', vi.fn(captureProvider(outbound)));
    const t = createReportingTest(modules);
    await post(t, 'enable');
    for (const unsafe of [
      { ...report(), message: 'Mail subject: private' },
      {
        ...report(),
        frames: [
          {
            kind: 'javascript',
            line: 1,
            column: 2,
            filename: 'https://private.example',
          },
        ],
      },
      {
        ...report(),
        breadcrumbs: [
          { operation: 'sync', stage: 'failed', text: 'private body' },
        ],
      },
      { ...report(), createdAt: Date.now() - 86_400_001 },
      { ...report(), createdAt: Date.now() + 301_000 },
    ]) {
      await expect(
        status(t, 'capture', { reports: [unsafe], metadata }),
      ).resolves.toBe(400);
    }
    expect(outbound).toHaveLength(0);
    await expect(
      body(t, 'capture', { reports: [report(), nativeReport()], metadata }),
    ).resolves.toStrictEqual({ status: 'accepted' });
    expect(outbound).toHaveLength(1);
    expect(outbound[0]).toContain('$exception_list');
    expect(outbound[0]).toContain(
      '"debug_id":"ABCDEF12-1234-4123-8123-123456789ABC"',
    );
    expect(outbound[0]).toContain('"$process_person_profile":true');
    expect(outbound[0]).toContain('"$set":{}');
    expect(outbound[0]).toContain(
      '"chunk_id":"app:///ios/1.0.0/1/index.bundle"',
    );
    expect(outbound[0]).toContain('"platform":"hermes"');
    expect(outbound[0]).toContain('Cannot convert undefined value to object');
    expect(outbound[0]).toContain('$geoip_disable');
    expect(outbound[0]).not.toContain(identity.credential);
    expect(outbound[0]).not.toContain('private');
  });

  it('keeps deletion pending through ingestion lag, accepted deletion and unverified event removal', async () => {
    expect.hasAssertions();
    configure();
    vi.useFakeTimers();
    const state = {
      visible: false,
      deleted: false,
      verified: false,
      failDelete: true,
    };
    vi.stubGlobal('fetch', vi.fn(provider(state, [])));
    const t = createReportingTest(modules);
    await post(t, 'enable');
    await post(t, 'capture', { reports: [report()], metadata });
    await expect(body(t, 'delete', { generation: 2 })).resolves.toMatchObject({
      status: 'pending',
    });
    await expect(status(t, 'enable', { generation: 3 })).resolves.toBe(409);
    state.visible = true;
    await expect(body(t, 'status', { generation: 2 })).resolves.toMatchObject({
      status: 'pending',
    });
    expect(state.deleted).toBe(false);
    await expect(body(t, 'status', { generation: 2 })).resolves.toMatchObject({
      status: 'pending',
    });
    expect(state.deleted).toBe(true);
    await expect(body(t, 'status', { generation: 2 })).resolves.toMatchObject({
      status: 'pending',
    });
    state.verified = true;
    await expect(body(t, 'status', { generation: 2 })).resolves.toStrictEqual({
      status: 'complete',
    });
    await t.backend.finishAllScheduledFunctions(() => vi.runAllTimers());
  });

  it('waits for an in-flight capture before the deletion cutoff, then finishes while the client is closed', async () => {
    expect.hasAssertions();
    configure();
    vi.useFakeTimers();
    const delivered = Promise.withResolvers<Response>();
    const entered = Promise.withResolvers<undefined>();
    const outbound: string[] = [];
    const state = {
      visible: true,
      deleted: false,
      verified: true,
      failDelete: false,
    };
    const downstream = provider(state, outbound);
    vi.stubGlobal(
      'fetch',
      vi.fn(delayedCapture(downstream, entered, delivered)),
    );
    const t = createReportingTest(modules);
    await post(t, 'enable');
    const capturing = post(t, 'capture', { reports: [report()], metadata });
    await entered.promise;
    await expect(body(t, 'delete', { generation: 2 })).resolves.toMatchObject({
      status: 'pending',
    });
    expect(outbound).toHaveLength(0);
    await expect(
      status(t, 'capture', { reports: [report()], metadata, generation: 2 }),
    ).resolves.toBe(409);
    delivered.resolve(Response.json({ status: 1 }));
    await capturing;
    // No status request drives deletion: Convex's durable scheduler does the work.
    await t.backend.finishAllScheduledFunctions(() => vi.runAllTimers());
    await expect(body(t, 'status', { generation: 2 })).resolves.toStrictEqual({
      status: 'complete',
    });
    expect(state.deleted).toBe(true);
  });

  it('bounds requests and fails closed without server configuration', async () => {
    expect.hasAssertions();
    const t = createReportingTest(modules);
    await post(t, 'enable');
    await expect(
      body(t, 'capture', { reports: [report()], metadata }),
    ).resolves.toMatchObject({ status: 'retry' });
    configure();
    await expect(
      status(t, 'capture', {
        reports: Array.from({ length: 11 }, report),
        metadata,
      }),
    ).resolves.toBe(400);
    await expect(
      status(t, 'enable', { extra: 'x'.repeat(65_536) }),
    ).resolves.toBe(400);
    await expect(
      status(t, 'capture', {
        reports: [report()],
        metadata: { ...metadata, appVersion: 'private@example.com' },
      }),
    ).resolves.toBe(400);
  });

  it('sends selected backend service health without any installation consent or identity', async () => {
    expect.hasAssertions();
    configure();
    const outbound: string[] = [];
    vi.stubGlobal('fetch', vi.fn(captureProvider(outbound)));
    const t = createReportingTest(modules);
    await t.captureServiceHealth();
    expect(outbound).toHaveLength(1);
    expect(outbound[0]).toContain('apns-wakeup-failed');
    expect(outbound[0]).toContain('"$process_person_profile":false');
    expect(outbound[0]).not.toContain(identity.installationId);
    expect(outbound[0]).not.toContain(identity.credential);
  });
});
