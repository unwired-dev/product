import type {
  CatalogValue,
  SpikeModule,
} from '@private-email/mail-core/testing/categorization-spike';

import {
  autorun,
  spikeSession,
} from '@private-email/mail-core/testing/categorization-spike';
import * as Schema from 'effect/Schema';

const parseBody = Schema.decodeSync(
  Schema.fromJsonString(Schema.Record(Schema.String, Schema.Unknown)),
);

const candidate = (run: string, mode: 'system' | 'custom') => ({
  run,
  mode,
  maxLength: 256,
  precisions: ['fp16', 'int8'] as const,
});

const catalog = (autorunMode: CatalogValue['autorun']): CatalogValue => ({
  candidates: [
    candidate('deberta-xsmall-body256', 'system'),
    candidate('deberta-mdeberta-body512', 'system'),
    candidate('xsmall-zs-adapted-body256-description', 'custom'),
    candidate('mdeberta-nli-adapted-body256-description', 'custom'),
  ],
  messages: [
    {
      id: 'synthetic:en-1',
      language: 'en',
      subject: 'Your change fee receipt',
    },
  ],
  categories: [],
  host: { model: 'iPhone18,2', os: 'Version 27.2' },
  evidence: '/tmp/categorization-spike.jsonl',
  autorun: autorunMode,
});

const result = JSON.stringify({
  process: {
    peakFootprintMB: 205,
    energyMillijoules: 6,
    thermalBefore: 'nominal',
    thermalAfter: 'nominal',
    mainThreadLagMs: { p95: 0.01 },
  },
  passMs: { p50: 13.4, p95: 15.3 },
});

// A native runner that records every request and answers it when `answer` says so.
function runner(answer: (request: string) => Promise<string>) {
  const sent: Array<{ kind: string; body: Record<string, unknown> }> = [];
  const handle = (kind: string) =>
    vi.fn<SpikeModule['classify']>((request, body) => {
      sent.push({ kind, body: parseBody(body) });
      return answer(request);
    });
  const module = {
    catalog: vi.fn<SpikeModule['catalog']>(() => Promise.resolve('')),
    classify: handle('classify'),
    benchmark: handle('benchmark'),
    golden: handle('golden'),
    computePlan: handle('plan'),
    progress: vi.fn<SpikeModule['progress']>(() => Promise.resolve(null)),
    cancel: vi.fn<SpikeModule['cancel']>(() => Promise.resolve()),
    release: vi.fn<SpikeModule['release']>(() => Promise.resolve(null)),
  } satisfies SpikeModule;
  return { module, sent };
}

const selection = {
  run: 'deberta-xsmall-body256',
  precision: 'fp16',
  unit: 'all',
  message: 'synthetic:en-1',
  count: 6,
} as const;

describe('categorization spike session', () => {
  it('the matrix run sends every request the evidence check expects, in order', async () => {
    expect.hasAssertions();

    const { module, sent } = runner(() => Promise.resolve(result));
    const session = spikeSession({
      module,
      catalog: catalog('matrix'),
      device: 'iPhone',
    });
    autorun(catalog('matrix'), session, vi.fn<() => void>());

    await vi.waitFor(() => {
      expect(sent).toHaveLength(43);
    });
    const custom = sent.filter(
      (each) => each.body.run === 'xsmall-zs-adapted-body256-description',
    );
    expect(custom.map((each) => each.kind)).toStrictEqual([
      'golden',
      'classify',
      'benchmark',
      'benchmark',
      'benchmark',
      'golden',
      'classify',
      'benchmark',
      'benchmark',
      'benchmark',
      'plan',
      'plan',
    ]);
    expect(
      custom
        .filter((each) => each.kind === 'benchmark')
        .map((each) => each.body.categoryCount),
    ).toStrictEqual([5, 20, 50, 5, 20, 50]);
    expect(sent[0]?.body).toMatchObject({ categoryCount: 0, rounds: 3 });
    expect(sent.slice(-3).map((each) => each.body.units)).toStrictEqual([
      'cpuOnly',
      'cpuAndGPU',
      'cpuAndNeuralEngine',
    ]);
    expect(session.getSnapshot().result?.passMs?.p50).toBe(13.4);
  });

  it('cancel hides a late result, and close stops the running request and releases the model', async () => {
    expect.hasAssertions();

    const answers: Array<(value: string) => void> = [];
    const { module } = runner(
      () =>
        // oxlint-disable-next-line promise/avoid-new -- Hold the native answer until the test settles it.
        new Promise<string>((resolve) => {
          answers.push(resolve);
        }),
    );
    const session = spikeSession({
      module,
      catalog: catalog(null),
      device: 'iPhone',
    });

    const cancelled = session.start('benchmark', selection);
    expect(session.getSnapshot().busy?.kind).toBe('benchmark');
    session.cancel();
    answers[0]?.(result);
    await cancelled;
    expect(session.getSnapshot()).toMatchObject({
      busy: undefined,
      result: undefined,
      failure:
        'Cancelled before the next model pass; no partial result is shown.',
    });

    const listener = vi.fn<() => void>();
    session.subscribe(listener);
    const closing = session.start('classify', selection);
    const request = module.classify.mock.calls[0]?.[0];
    session.close();
    answers[1]?.(result);
    await closing;
    expect({
      cancelled: module.cancel.mock.lastCall,
      releases: module.release.mock.calls.length,
      notifications: listener.mock.calls.length,
      result: session.getSnapshot().result,
    }).toStrictEqual({
      cancelled: [request],
      releases: 2,
      notifications: 1,
      result: undefined,
    });
  });

  it('a failed or unreadable native answer stays unavailable, without any fallback', async () => {
    expect.hasAssertions();

    vi.spyOn(console, 'error').mockReturnValue(undefined);
    for (const answer of [
      () => Promise.reject(new Error('Synthetic Core ML failure')),
      () => Promise.resolve('{"process":{}}'),
    ]) {
      const { module } = runner(answer);
      const session = spikeSession({
        module,
        catalog: catalog(null),
        device: 'iPad',
      });
      await session.start('classify', selection);
      expect(session.getSnapshot()).toMatchObject({
        result: undefined,
        failure:
          'The candidate could not run on this iPad. Categorization stays unavailable; it has no server fallback.',
      });
    }
  });
});
