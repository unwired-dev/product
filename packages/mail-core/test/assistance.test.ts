import type { NativeAssistance, SummaryInput } from '../src/assistance.ts';

import {
  createMessageSummary,
  summaryInput,
  summaryInputLimit,
} from '../src/assistance.ts';
import {
  createMockMailSession,
  syntheticSummary,
} from '../src/testing/mock-session.ts';

interface Asked {
  readonly request: string;
  readonly input: string;
  readonly answer: PromiseWithResolvers<unknown>;
}

// A native model whose answers the test releases, recording what it was asked.
function scriptedAssistance(availability: unknown = 'available') {
  const asked: Asked[] = [];
  const cancelled: string[] = [];
  const native: NativeAssistance = {
    availability: () => Promise.resolve(availability),
    summarize: (request, input) => {
      const answer = Promise.withResolvers<unknown>();
      asked.push({ request, input, answer });
      return answer.promise;
    },
    cancel: (request) => {
      cancelled.push(request);
      return Promise.resolve(null);
    },
  };
  // The nth summarize call, once the store has made it.
  const nth = async (index: number) => {
    await vi.waitFor(() => {
      expect(asked.length).toBeGreaterThan(index);
    });
    const call = asked[index];
    if (call === undefined) {
      throw new Error('Expected a summarize call');
    }
    return call;
  };
  return { native, nth, cancelled };
}

const input = (body: string): SummaryInput => {
  const admitted = summaryInput({ subject: 'Plans', body });
  if (admitted === undefined) {
    throw new Error('Expected readable input');
  }
  return admitted;
};

describe('on-device message summaries', () => {
  /* oxlint-disable vitest/max-expects -- Each case proves one summary path end to end. */
  it('admits only the given subject and readable body, cut at the limit', () => {
    expect.hasAssertions();
    expect(summaryInput({ subject: 'Plans', body: ' \n​ ' })).toBeUndefined();
    expect(summaryInput({ body: 'Lunch at noon?' })).toStrictEqual({
      text: 'Lunch at noon?',
      omitted: false,
    });
    // A cut never leaves half of a surrogate pair.
    const prefix = 'Subject: Plans\n\n';
    const split = summaryInput({
      subject: 'Plans',
      body: `${'a'.repeat(summaryInputLimit - prefix.length - 1)}😀 tail`,
    });
    expect(split?.text).toHaveLength(summaryInputLimit - 1);
    expect(split?.omitted).toBe(true);
  });

  it('summarizes the bounded input and discloses that the rest was not read', async () => {
    expect.hasAssertions();
    const { native, nth } = scriptedAssistance();
    const summary = createMessageSummary(native);
    const long = input(
      `Please confirm the venue by Friday. ${'x'.repeat(9000)}`,
    );
    const done = summary.summarize(long);
    const call = await nth(0);
    expect(summary.getSnapshot(long)).toStrictEqual({ kind: 'summarizing' });
    expect(call.input).toHaveLength(summaryInputLimit);
    expect(call.input).toMatch(/^Subject: Plans\n\nPlease confirm/u);
    call.answer.resolve('  Confirm the venue by Friday.  ');
    await done;
    expect(summary.getSnapshot(long)).toStrictEqual({
      kind: 'ready',
      summary: 'Confirm the venue by Friday.',
      omitted: true,
    });
  });

  it.each([
    'device-ineligible',
    'assistance-disabled',
    'model-not-ready',
    'unsupported-locale',
  ] as const)(
    'reports the system model as %s without asking it or logging',
    async (reason) => {
      expect.hasAssertions();
      const logged = vi.spyOn(console, 'error').mockReturnValue(undefined);
      const { native, cancelled } = scriptedAssistance(reason);
      const summary = createMessageSummary(native);
      const message = input('Lunch at noon?');
      await summary.summarize(message);
      expect(summary.getSnapshot(message)).toStrictEqual({
        kind: 'unavailable',
        reason,
      });
      expect(cancelled).toStrictEqual([]);
      expect(logged).not.toHaveBeenCalled();
    },
  );

  it.each([
    [
      'unsupported-locale',
      { kind: 'unavailable', reason: 'unsupported-locale' },
    ],
    ['model-not-ready', { kind: 'unavailable', reason: 'model-not-ready' }],
    ['refused', { kind: 'refused' }],
    ['cancelled', { kind: 'cancelled' }],
  ] as const)(
    'reports a %s rejection as %j without logging',
    async (code, expected) => {
      expect.hasAssertions();
      const logged = vi.spyOn(console, 'error').mockReturnValue(undefined);
      const { native, nth } = scriptedAssistance();
      const summary = createMessageSummary(native);
      const message = input('Lunch at noon?');
      const done = summary.summarize(message);
      const call = await nth(0);
      call.answer.reject({ code });
      await done;
      expect(summary.getSnapshot(message)).toStrictEqual(expected);
      expect(logged).not.toHaveBeenCalled();
    },
  );

  it('fails closed on an unknown availability', async () => {
    expect.hasAssertions();
    const logged = vi.spyOn(console, 'error').mockReturnValue(undefined);
    const { native } = scriptedAssistance('cloud');
    const summary = createMessageSummary(native);
    const message = input('Lunch at noon?');
    await summary.summarize(message);
    expect(summary.getSnapshot(message)).toStrictEqual({ kind: 'failed' });
    expect(logged).toHaveBeenCalledWith(
      expect.any(String),
      'On-device assistance failed:',
      'invalid at (root)',
    );
  });

  it.each([
    [
      'an unrecognized rejection',
      (answer: PromiseWithResolvers<unknown>) => {
        answer.reject({ code: 'unavailable', message: 'Lunch at noon?' });
      },
    ],
    [
      'a malformed summary',
      (answer: PromiseWithResolvers<unknown>) => {
        answer.resolve(42);
      },
    ],
    [
      'an oversized summary',
      (answer: PromiseWithResolvers<unknown>) => {
        answer.resolve('Lunch at noon? '.repeat(300));
      },
    ],
    [
      'an empty summary',
      (answer: PromiseWithResolvers<unknown>) => {
        answer.resolve(' \n ');
      },
    ],
  ] as const)(
    'fails closed on %s and logs no mail content',
    async (_case, settle) => {
      expect.hasAssertions();
      const logged = vi.spyOn(console, 'error').mockReturnValue(undefined);
      const { native, nth } = scriptedAssistance();
      const summary = createMessageSummary(native);
      const message = input('Lunch at noon?');
      const done = summary.summarize(message);
      const call = await nth(0);
      settle(call.answer);
      await done;
      expect(summary.getSnapshot(message)).toStrictEqual({ kind: 'failed' });
      expect(JSON.stringify(logged.mock.calls)).not.toContain('Lunch');
    },
  );

  it('cancels the native request and drops its late result', async () => {
    expect.hasAssertions();
    const { native, nth, cancelled } = scriptedAssistance();
    const summary = createMessageSummary(native);
    const message = input('Lunch at noon?');
    const done = summary.summarize(message);
    const first = await nth(0);
    summary.cancel();
    expect(cancelled).toStrictEqual([first.request]);
    expect(summary.getSnapshot(message)).toStrictEqual({ kind: 'cancelled' });
    first.answer.resolve('Too late.');
    await done;
    expect(summary.getSnapshot(message)).toStrictEqual({ kind: 'cancelled' });

    const again = summary.summarize(message);
    const second = await nth(1);
    second.answer.resolve('Lunch at noon.');
    await again;
    expect(summary.getSnapshot(message)).toMatchObject({
      kind: 'ready',
      summary: 'Lunch at noon.',
    });
  });

  it.each([
    ['cancel', 'cancelled'],
    ['discard', 'idle'],
  ] as const)(
    'does not start inference after %s while availability is pending',
    async (stop, expected) => {
      expect.hasAssertions();
      const availability = Promise.withResolvers<unknown>();
      const generate = vi.fn<NativeAssistance['summarize']>(() =>
        Promise.resolve('Too late.'),
      );
      const summary = createMessageSummary({
        availability: () => availability.promise,
        summarize: generate,
        cancel: () => Promise.resolve(null),
      });
      const message = input('Lunch at noon?');
      const done = summary.summarize(message);
      summary[stop]();
      availability.resolve('available');
      await done;
      expect(generate).not.toHaveBeenCalled();
      expect(summary.getSnapshot(message)).toStrictEqual({
        kind: expected,
      });
    },
  );

  it('keeps a result only for the input it was requested for', async () => {
    expect.hasAssertions();
    const { native, nth, cancelled } = scriptedAssistance();
    const summary = createMessageSummary(native);
    const first = input('Lunch at noon?');
    const edited = input('Lunch at one?');
    const firstDone = summary.summarize(first);
    const firstCall = await nth(0);
    // The captured input changed: the pending request does not belong to the new text.
    expect(summary.getSnapshot(edited)).toStrictEqual({ kind: 'idle' });
    const editedDone = summary.summarize(edited);
    const editedCall = await nth(1);
    expect(cancelled).toStrictEqual([firstCall.request]);
    firstCall.answer.resolve('Lunch at noon.');
    await firstDone;
    expect(summary.getSnapshot(edited)).toStrictEqual({ kind: 'summarizing' });
    editedCall.answer.resolve('Lunch at one.');
    await editedDone;
    expect(summary.getSnapshot(edited)).toMatchObject({
      summary: 'Lunch at one.',
    });
    expect(summary.getSnapshot(first)).toStrictEqual({ kind: 'idle' });

    summary.discard();
    expect(summary.getSnapshot(edited)).toStrictEqual({ kind: 'idle' });
  });
  /* oxlint-enable vitest/max-expects */

  it('gives Mock Mail Sessions fixed outcomes', async () => {
    expect.hasAssertions();
    const message = input('Lunch at noon?');
    const available = createMessageSummary(
      createMockMailSession('open-read-relaunch').assistance,
    );
    const unavailable = createMessageSummary(
      createMockMailSession('assistance-unavailable').assistance,
    );
    await Promise.all([
      available.summarize(message),
      unavailable.summarize(message),
    ]);
    expect(available.getSnapshot(message)).toStrictEqual({
      kind: 'ready',
      summary: syntheticSummary,
      omitted: false,
    });
    expect(unavailable.getSnapshot(message)).toStrictEqual({
      kind: 'unavailable',
      reason: 'model-not-ready',
    });
  });
});
