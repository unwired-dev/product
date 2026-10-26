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

const systemSmall = 'deberta-xsmall-body256';
const systemBase = 'deberta-mdeberta-body512';
const customSmall = 'xsmall-zs-adapted-body256-description';
const customBase = 'mdeberta-nli-adapted-body256-description';

const catalog = (autorunMode: CatalogValue['autorun']): CatalogValue => ({
  candidates: [
    candidate(systemSmall, 'system'),
    candidate(systemBase, 'system'),
    candidate(customSmall, 'custom'),
    candidate(customBase, 'custom'),
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

const categorySelection = (count: number | readonly string[]) =>
  typeof count === 'number' ? { categoryCount: count } : { categories: count };

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
      expect([sent.length, session.getSnapshot().busy]).toStrictEqual([
        43,
        undefined,
      ]);
    });
    const golden = [
      'online-purchases',
      'flights-booked',
      'statements',
      'kids-school',
      'event-invitations',
      'family-friends',
    ];
    // Pin the evidence contract independently of the scheduler's loops and exported constants.
    const expected = [
      ['golden', systemSmall, 'fp16', 'all', 0],
      ['classify', systemSmall, 'fp16', 'all', 0],
      ['benchmark', systemSmall, 'fp16', 'all', 0],
      ['golden', systemSmall, 'int8', 'all', 0],
      ['classify', systemSmall, 'int8', 'all', 0],
      ['benchmark', systemSmall, 'int8', 'all', 0],
      ['plan', systemSmall, 'fp16', 'all', 0],
      ['plan', systemSmall, 'fp16', 'cpuAndNeuralEngine', 0],
      ['golden', systemBase, 'fp16', 'all', 0],
      ['classify', systemBase, 'fp16', 'all', 0],
      ['benchmark', systemBase, 'fp16', 'all', 0],
      ['golden', systemBase, 'int8', 'all', 0],
      ['classify', systemBase, 'int8', 'all', 0],
      ['benchmark', systemBase, 'int8', 'all', 0],
      ['plan', systemBase, 'fp16', 'all', 0],
      ['plan', systemBase, 'fp16', 'cpuAndNeuralEngine', 0],
      ['golden', customSmall, 'fp16', 'all', golden],
      ['classify', customSmall, 'fp16', 'all', golden],
      ['benchmark', customSmall, 'fp16', 'all', 5],
      ['benchmark', customSmall, 'fp16', 'all', 20],
      ['benchmark', customSmall, 'fp16', 'all', 50],
      ['golden', customSmall, 'int8', 'all', golden],
      ['classify', customSmall, 'int8', 'all', golden],
      ['benchmark', customSmall, 'int8', 'all', 5],
      ['benchmark', customSmall, 'int8', 'all', 20],
      ['benchmark', customSmall, 'int8', 'all', 50],
      ['plan', customSmall, 'fp16', 'all', golden],
      ['plan', customSmall, 'fp16', 'cpuAndNeuralEngine', golden],
      ['golden', customBase, 'fp16', 'all', golden],
      ['classify', customBase, 'fp16', 'all', golden],
      ['benchmark', customBase, 'fp16', 'all', 5],
      ['benchmark', customBase, 'fp16', 'all', 20],
      ['benchmark', customBase, 'fp16', 'all', 50],
      ['golden', customBase, 'int8', 'all', golden],
      ['classify', customBase, 'int8', 'all', golden],
      ['benchmark', customBase, 'int8', 'all', 5],
      ['benchmark', customBase, 'int8', 'all', 20],
      ['benchmark', customBase, 'int8', 'all', 50],
      ['plan', customBase, 'fp16', 'all', golden],
      ['plan', customBase, 'fp16', 'cpuAndNeuralEngine', golden],
      ['benchmark', systemSmall, 'fp16', 'cpuOnly', 0],
      ['benchmark', systemSmall, 'fp16', 'cpuAndGPU', 0],
      ['benchmark', systemSmall, 'fp16', 'cpuAndNeuralEngine', 0],
    ] as const;
    expect(sent).toStrictEqual(
      expected.map(([kind, run, precision, units, categories]) => ({
        kind,
        body: {
          run,
          precision,
          units,
          message: 'synthetic:en-1',
          rounds: 3,
          ...categorySelection(categories),
        },
      })),
    );
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

  it('a late picker choice keeps the running workload and the closed page unchanged', async () => {
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

    // A picker opened before Classify can deliver its choice after Setup locks.
    const running = session.start('classify', selection);
    session.choose({ ...selection, precision: 'int8' });
    expect(session.getSnapshot().selection.precision).toBe('fp16');
    answers[0]?.(result);
    await running;
    session.close();
    session.choose({ ...selection, precision: 'int8' });
    expect(session.getSnapshot().selection.precision).toBe('fp16');
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
