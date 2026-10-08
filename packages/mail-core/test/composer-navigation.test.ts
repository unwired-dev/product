import { createComposerNavigation } from '../src/composer-navigation.ts';

// A composer's finishing step that answers each attempt in turn, then allows leaving.
const finishing = (
  answers: ReadonlyArray<() => Promise<boolean>>,
): (() => Promise<boolean>) => {
  const queue = [...answers];
  return async () => (queue.shift() ?? (async () => true))();
};

describe('leaving an open composer', () => {
  /* oxlint-disable vitest/max-expects -- One journey proves the guard end to end. */
  it('runs one leave at a time and recovers when finishing refuses or fails', async () => {
    expect.hasAssertions();
    const navigation = createComposerNavigation();
    // Nothing registered: navigation proceeds.
    await expect(navigation.leave()).resolves.toBe(true);
    const unregister = navigation.register(
      finishing([
        async () => false,
        async () => {
          throw new Error('storage failed');
        },
      ]),
    );
    // A composer that cannot finish stays open, and a second request meanwhile is refused.
    const first = navigation.leave();
    await expect(navigation.leave()).resolves.toBe(false);
    await expect(first).resolves.toBe(false);
    // A failed finish keeps the composer open without blocking the next attempt.
    await expect(navigation.leave()).resolves.toBe(false);
    await expect(navigation.leave()).resolves.toBe(true);
    unregister();
    await expect(navigation.leave()).resolves.toBe(true);
  });
  /* oxlint-enable vitest/max-expects */

  it('removes the empty Draft it started when preparing it fails, and keeps one that gained content', async () => {
    expect.hasAssertions();
    const navigation = createComposerNavigation();
    const abandoned: string[] = [];
    const drafts = {
      create: async () => 'new-draft',
      abandon: async (id: string) => {
        abandoned.push(id);
        return true;
      },
    };
    const mailbox = { id: 'connection-alex', address: 'alex@example.invalid' };
    await expect(
      navigation.create(drafts, mailbox, async () => false),
    ).resolves.toBeUndefined();
    // Abandoning removes only an empty Draft, so content added before the failure is kept.
    expect(abandoned).toStrictEqual(['new-draft']);
    await expect(
      navigation.create(drafts, mailbox, async () => true),
    ).resolves.toBe('new-draft');
    expect(abandoned).toStrictEqual(['new-draft']);
  });
});
