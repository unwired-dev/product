import {
  runAssistanceQualification,
  startAssistanceQualification,
} from '@private-email/mail-core/testing/assistance-qualification';
import * as Schema from 'effect/Schema';

const parseLine = Schema.decodeSync(
  Schema.fromJsonString(Schema.Record(Schema.String, Schema.Unknown)),
);

const rejection = (code: string) =>
  Object.assign(new Error(`Synthetic ${code}`), { code });

// A native binding whose answers take a second, with the cancellation behavior under test.
function binding({
  availability = 'available',
  honorsCancel = true,
  nativeCancelCode,
}: Readonly<{
  availability?: string;
  honorsCancel?: boolean;
  nativeCancelCode?: string;
}> = {}) {
  const pending = new Map<string, (error: Error) => void>();
  const answer = <T>(request: string, value: T) =>
    // oxlint-disable-next-line promise/avoid-new -- A native answer the fake clock releases.
    new Promise<T>((resolve, reject) => {
      pending.set(request, reject);
      setTimeout(() => {
        resolve(value);
      }, 1000);
    });
  const generate = (request: string) => {
    if (request === 'qualification-cancel' && nativeCancelCode !== undefined) {
      return Promise.reject(rejection(nativeCancelCode));
    }
    return availability === 'available'
      ? answer(request, `Result for ${request}.`)
      : Promise.reject(rejection(availability));
  };
  const lines: Array<Record<string, unknown>> = [];
  return {
    lines,
    assistance: {
      availability: () => Promise.resolve(availability),
      summarize: generate,
      rewrite: generate,
      suggestReply: generate,
      translationLanguages: () =>
        Promise.resolve([
          { code: 'de', name: 'German' },
          { code: 'en', name: 'English' },
        ]),
      translate: (request: string, input: string, target: string) => {
        if (/^[\d\s]+$/u.test(input)) {
          return Promise.reject(rejection('unidentified-language'));
        }
        if (target === 'en' && input.startsWith('Please')) {
          return Promise.reject(rejection('same-language'));
        }
        return answer(request, { source: 'de', text: 'Translated text.' });
      },
      cancel: (request: string) => {
        if (honorsCancel) {
          pending.get(request)?.(rejection('cancelled'));
        }
        return Promise.resolve(null);
      },
    },
    qualification: {
      begin: () =>
        Promise.resolve({
          hardware: 'Mac16,10',
          system: 'Version 27.0.1 (Build 26A434)',
          locale: 'en_US',
          languages: ['en-US'],
          commit: '',
          // Old native metadata must not leak local accounts or device paths into evidence.
          evidence:
            '/Users/synthetic-private-account/device-udid/evidence.jsonl',
        }),
      record: (line: string) => {
        lines.push(parseLine(line));
        return Promise.resolve(null);
      },
    },
  };
}

async function run(native: ReturnType<typeof binding>) {
  vi.useFakeTimers();
  try {
    const done = runAssistanceQualification(native);
    await vi.runAllTimersAsync();
    await done;
  } finally {
    vi.useRealTimers();
  }
  const byKind = (kind: string) =>
    native.lines.filter((line) => line.kind === kind);
  return { byKind, complete: byKind('complete')[0] };
}

describe('assistance qualification corpus run', () => {
  it('an available binding that honors cancellation passes every corpus check', async () => {
    expect.hasAssertions();

    const { byKind, complete } = await run(binding());

    expect(complete).toMatchObject({ pass: 20, limited: 0, fail: 0 });
    expect(byKind('device')[0]).toMatchObject({
      corpusVersion: 1,
      hardware: 'Mac16,10',
      availability: 'available',
      translationLanguages: ['en', 'de'],
    });
    // The cut long message is reported, with the generated text kept as evidence.
    expect(byKind('summary')).toContainEqual(
      expect.objectContaining({
        id: 'long-newsletter',
        state: 'ready',
        omitted: true,
        result: 'pass',
      }),
    );
    expect(byKind('native-cancel')[0]).toMatchObject({ code: 'cancelled' });
    expect(byKind('stale-result')[0]).toMatchObject({
      stale: 'idle',
      current: 'ready',
    });
  });

  it('a binding that ignores cancellation fails only the native cancellation check', async () => {
    expect.hasAssertions();

    const { byKind, complete } = await run(binding({ honorsCancel: false }));

    // The shared core still drops the late result, so only the binding's own contract fails.
    expect(byKind('native-cancel')[0]).toMatchObject({
      code: 'completed',
      result: 'fail',
    });
    expect(byKind('summary-cancel')[0]).toMatchObject({ result: 'pass' });
    expect(complete).toMatchObject({ pass: 19, fail: 1 });
  });

  it('an unavailable model is a limitation that leaves Translation qualified', async () => {
    expect.hasAssertions();

    const { byKind, complete } = await run(
      binding({ availability: 'assistance-disabled' }),
    );

    expect(byKind('device')[0]).toMatchObject({
      availability: 'assistance-disabled',
    });
    for (const kind of ['summary', 'rewrite', 'reply']) {
      for (const line of byKind(kind)) {
        expect(line).toMatchObject({
          state: 'unavailable',
          reason: 'assistance-disabled',
          result: 'limited',
        });
      }
    }
    expect(byKind('translation').every(({ result }) => result === 'pass')).toBe(
      true,
    );
    expect(complete).toMatchObject({ fail: 0 });
  });

  it('unexpected native cancellation rejections fail instead of qualifying as capability limits', async () => {
    expect.hasAssertions();

    const { byKind, complete } = await run(
      binding({ nativeCancelCode: 'unavailable' }),
    );

    expect(byKind('native-cancel')[0]).toMatchObject({
      code: 'unavailable',
      result: 'fail',
    });
    expect(complete).toMatchObject({ pass: 19, limited: 0, fail: 1 });
  });

  it('recorded device metadata excludes native filesystem paths and local account names', async () => {
    expect.hasAssertions();

    const { byKind } = await run(binding());

    expect(byKind('device')[0]).not.toHaveProperty('evidence');
    expect(JSON.stringify(byKind('device'))).not.toContain(
      'synthetic-private-account',
    );
  });

  it('a run that cannot start records only an allow-listed stop diagnostic', async () => {
    expect.hasAssertions();

    const errors = vi.spyOn(console, 'error').mockReturnValue(undefined);
    const path = '/Users/synthetic-private-account/Library/evidence.jsonl';
    for (const begin of [
      () => Promise.resolve({ hardware: 'Mac16,10' }),
      () => Promise.reject(new Error(`Cannot open ${path}`)),
    ]) {
      const native = binding();
      startAssistanceQualification(() => ({
        ...native,
        qualification: { ...native.qualification, begin },
      }));
      await vi.waitFor(() => {
        expect(native.lines.at(-1)).toMatchObject({ kind: 'stopped' });
      });
      expect(JSON.stringify(native.lines)).not.toContain(path);
    }
    expect(errors.mock.calls).toStrictEqual([
      ['Assistance qualification stopped:', 'unrecognized error'],
      ['Assistance qualification stopped:', 'Error'],
    ]);
  });
});
