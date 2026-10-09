import type { NativeAssistance, SummaryInput } from '../src/assistance.ts';
import type { SemanticDocument } from '../src/semantic-document.ts';

import {
  canRetryAssistance,
  createDraftAssistance,
  createMessageSummary,
  replyInput,
  rewriteInput,
  summaryInput,
  summaryInputLimit,
} from '../src/assistance.ts';
import { imageCharacter } from '../src/semantic-document.ts';
import {
  createMockMailSession,
  syntheticReply,
  syntheticRewrite,
  syntheticSummary,
} from '../src/testing/mock-session.ts';

interface Asked {
  readonly request: string;
  readonly input: string;
  readonly answer: PromiseWithResolvers<unknown>;
  readonly operation: 'summarize' | 'rewrite' | 'reply';
}

// A native model whose answers the test releases, recording what it was asked.
function scriptedAssistance(availability: unknown = 'available') {
  const asked: Asked[] = [];
  const cancelled: string[] = [];
  const respond =
    (operation: Asked['operation']) => (request: string, input: string) => {
      const answer = Promise.withResolvers<unknown>();
      asked.push({ request, input, answer, operation });
      return answer.promise;
    };
  const native: NativeAssistance = {
    availability: () => Promise.resolve(availability),
    summarize: respond('summarize'),
    rewrite: respond('rewrite'),
    suggestReply: respond('reply'),
    cancel: (request) => {
      cancelled.push(request);
      return Promise.resolve(null);
    },
  };
  // The nth model call, once the store has made it.
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
      text: 'Confirm the venue by Friday.',
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
      text: 'Lunch at noon.',
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
        rewrite: generate,
        suggestReply: generate,
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
      text: 'Lunch at one.',
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
      text: syntheticSummary,
      omitted: false,
    });
    expect(unavailable.getSnapshot(message)).toStrictEqual({
      kind: 'unavailable',
      reason: 'model-not-ready',
    });
  });
});

// A reply's quoted correspondence, with an inline image the model never reads.
const quoted = (text: string): SemanticDocument => [
  {
    kind: 'paragraph',
    spans: [{ text: 'On Monday, Maya Chen <maya@example.invalid> wrote:' }],
  },
  {
    kind: 'quote',
    spans: [
      { text },
      {
        text: imageCharacter,
        image: {
          id: 'image0001',
          name: 'map.png',
          type: 'image/png',
          state: 'importing',
        },
      },
    ],
  },
];

// Admitted input, or a failed test.
const admitted = <T>(value: T | undefined) => {
  if (value === undefined) {
    throw new Error('Expected admitted input');
  }
  return value;
};

// The fixture rewrite every store case requests.
const rewriteFixture = () => admitted(rewriteInput('Lets meet friday ok'));

const recipients = [
  { name: 'Maya Chen', address: 'maya@example.invalid' },
  { address: 'carol@example.invalid' },
];

describe('on-device Draft rewrites and reply suggestions', () => {
  /* oxlint-disable vitest/max-expects -- Each case proves one Draft assistance path end to end. */
  it('admits only authored text, recipient names and the quoted message, within the limit', () => {
    expect.hasAssertions();
    const reply = replyInput({
      authored: 'Friday works.',
      recipients,
      quoted: quoted('Shall we meet on Friday?'),
    });
    expect(reply).toStrictEqual({
      purpose: 'reply',
      text: 'Recipients: Maya Chen\n\nReply so far:\nFriday works.\n\nMessage being answered:\nOn Monday, Maya Chen  wrote:\nShall we meet on Friday?',
      omitted: false,
    });
    // Addresses are never admitted, only display names.
    expect(reply?.text).not.toContain('@');
    // A long quoted message is cut so the whole input stays within the limit, and says so.
    const long = replyInput({
      authored: '',
      recipients,
      quoted: quoted(`Shall we meet? ${'x'.repeat(9000)}`),
    });
    expect(long?.text).toHaveLength(
      // The attribution's address is removed after the cut.
      summaryInputLimit - '<maya@example.invalid>'.length,
    );
    expect(long?.omitted).toBe(true);
    // Framing and recipient names consume the same budget; never send a reply without context.
    expect(
      replyInput({
        authored: 'a'.repeat(summaryInputLimit),
        recipients,
        quoted: quoted('Hi'),
      }),
    ).toBeUndefined();
    // The authored text is replaced by the result, so it is never cut or stripped of images.
    expect(
      replyInput({
        authored: 'a'.repeat(summaryInputLimit + 1),
        recipients,
        quoted: quoted('Hi'),
      }),
    ).toBeUndefined();
    expect(
      replyInput({
        authored: `See ${imageCharacter}`,
        recipients,
        quoted: quoted('Hi'),
      }),
    ).toBeUndefined();
    expect(rewriteInput('Lets meet friday ok')).toStrictEqual({
      purpose: 'rewrite',
      text: 'Lets meet friday ok',
      omitted: false,
    });
    expect(rewriteInput(' \n ')).toBeUndefined();
    expect(rewriteInput(`See ${imageCharacter}`)).toBeUndefined();
    expect(rewriteInput('a'.repeat(summaryInputLimit + 1))).toBeUndefined();
  });

  it('stops reading quoted spans and recipient names even when the name prefix is redacted', () => {
    expect.hasAssertions();
    const reply = replyInput({
      authored: 'Yes',
      recipients: [
        {
          name: `${'x'.repeat(499)}@${'x'.repeat(100_000)}`,
          address: 'maya@example.invalid',
        },
        {
          get name(): string {
            throw new Error('Read beyond the recipient prefix');
          },
          address: 'bob@example.invalid',
        },
      ],
      quoted: [
        { kind: 'paragraph', spans: [{ text: 'q'.repeat(100_000) }] },
        {
          kind: 'paragraph',
          get spans(): SemanticDocument[number]['spans'] {
            throw new Error('Read beyond the quoted prefix');
          },
        },
      ],
    });
    expect(reply?.text).toHaveLength(summaryInputLimit);
    expect(reply?.omitted).toBe(true);
  });

  it('keeps address-redacted recipient context well-formed at the name bound', async () => {
    expect.hasAssertions();
    const { native, nth } = scriptedAssistance();
    const assistance = createDraftAssistance(native);
    const reply = admitted(
      replyInput({
        authored: 'Yes',
        recipients: [
          { name: `a@b ${'x'.repeat(496)}😀`, address: 'maya@example.invalid' },
        ],
        quoted: quoted('Shall we meet?'),
      }),
    );
    const replying = assistance.start(reply);
    const request = await nth(0);
    expect(request.input.isWellFormed()).toBe(true);
    expect(request.input).not.toContain('@');
    request.answer.resolve('Yes, let us meet.');
    await replying;
    expect(assistance.getSnapshot(reply)).toMatchObject({ kind: 'ready' });
  });

  it('asks the model for the requested operation and keeps its trimmed result', async () => {
    expect.hasAssertions();
    const { native, nth } = scriptedAssistance();
    const assistance = createDraftAssistance(native);
    const rewrite = rewriteFixture();
    const reply = admitted(
      replyInput({
        authored: '',
        recipients,
        quoted: quoted('Shall we meet?'),
      }),
    );
    const rewriting = assistance.start(rewrite);
    const first = await nth(0);
    expect(first).toMatchObject({ operation: 'rewrite', input: rewrite.text });
    expect(assistance.getSnapshot(rewrite)).toStrictEqual({
      kind: 'generating',
    });
    first.answer.resolve(' Shall we meet on Friday? ');
    await rewriting;
    expect(assistance.getSnapshot(rewrite)).toStrictEqual({
      kind: 'ready',
      text: 'Shall we meet on Friday?',
      omitted: false,
    });
    // A result belongs to its own input.
    expect(assistance.getSnapshot(reply)).toStrictEqual({ kind: 'idle' });
    const replying = assistance.start(reply);
    const second = await nth(1);
    expect(second).toMatchObject({ operation: 'reply', input: reply.text });
    second.answer.resolve('Friday works for me.');
    await replying;
    expect(assistance.getSnapshot(reply)).toMatchObject({
      kind: 'ready',
      text: 'Friday works for me.',
    });
  });

  it.each([
    {
      outcome: 'refused',
      rejection: { code: 'refused' },
      expected: { kind: 'refused' },
      retry: false,
    },
    {
      outcome: 'unavailable',
      rejection: { code: 'model-not-ready' },
      expected: { kind: 'unavailable', reason: 'model-not-ready' },
      retry: true,
    },
    {
      outcome: 'failed',
      rejection: new Error('Lets meet friday ok'),
      expected: { kind: 'failed' },
      retry: true,
    },
  ] as const)(
    'leaves the Draft text unchanged when the model is $outcome, without logging it',
    async ({ rejection, expected, retry }) => {
      expect.hasAssertions();
      const logged = vi.spyOn(console, 'error').mockReturnValue(undefined);
      const { native, nth } = scriptedAssistance();
      const assistance = createDraftAssistance(native);
      const rewrite = rewriteFixture();
      const done = assistance.start(rewrite);
      const call = await nth(0);
      call.answer.reject(rejection);
      await done;
      const state = assistance.getSnapshot(rewrite);
      expect(state).toStrictEqual(expected);
      expect(canRetryAssistance(state)).toBe(retry);
      expect(JSON.stringify(logged.mock.calls)).not.toContain('friday');
    },
  );

  it('rejects an oversized result and drops a cancelled late result', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const { native, nth, cancelled } = scriptedAssistance();
    const assistance = createDraftAssistance(native);
    const rewrite = rewriteFixture();
    const oversized = assistance.start(rewrite);
    const first = await nth(0);
    first.answer.resolve('x'.repeat(summaryInputLimit * 2 + 1));
    await oversized;
    expect(assistance.getSnapshot(rewrite)).toStrictEqual({ kind: 'failed' });
    const late = assistance.start(rewrite);
    const call = await nth(1);
    assistance.cancel();
    expect(cancelled).toStrictEqual([call.request]);
    call.answer.resolve('Too late.');
    await late;
    expect(assistance.getSnapshot(rewrite)).toStrictEqual({
      kind: 'cancelled',
    });
  });
  /* oxlint-enable vitest/max-expects */

  it('gives Mock Mail Sessions fixed Draft outcomes', async () => {
    expect.hasAssertions();
    const rewrite = rewriteFixture();
    const reply = { ...rewrite, purpose: 'reply' as const };
    const available = createDraftAssistance(
      createMockMailSession('open-read-relaunch').assistance,
    );
    await available.start(rewrite);
    expect(available.getSnapshot(rewrite)).toMatchObject({
      text: syntheticRewrite,
    });
    await available.start(reply);
    expect(available.getSnapshot(reply)).toMatchObject({
      text: syntheticReply,
    });
    const unavailable = createDraftAssistance(
      createMockMailSession('assistance-unavailable').assistance,
    );
    await unavailable.start(reply);
    expect(unavailable.getSnapshot(reply)).toStrictEqual({
      kind: 'unavailable',
      reason: 'model-not-ready',
    });
  });
});
