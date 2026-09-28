import * as Effect from 'effect/Effect';
import * as Exit from 'effect/Exit';
import * as ManagedRuntime from 'effect/ManagedRuntime';

import { listInbox, MockMailbox, readMessage } from '../src/index.ts';

describe('mock mailbox read boundary', () => {
  it('opens the selected message instead of whichever message is first', async () => {
    expect.hasAssertions();
    const runtime = ManagedRuntime.make(MockMailbox);
    try {
      const message = await runtime.runPromise(readMessage('weekend-walk'));
      expect(message.subject).toBe('Saturday, by the river?');
      expect(message.address).toBe('oliver@example.com');
      expect(message.body).toContain('meet you by the river at ten');
    } finally {
      await runtime.dispose();
    }
  });

  it('rejects an unknown route without exposing another message', async () => {
    expect.hasAssertions();
    const result = await Effect.runPromiseExit(
      readMessage('missing-message').pipe(Effect.provide(MockMailbox)),
    );
    expect(Exit.isFailure(result)).toBe(true);
    const failure = await Effect.runPromise(
      readMessage('missing-message').pipe(
        Effect.flip,
        Effect.provide(MockMailbox),
      ),
    );
    expect(failure).toMatchObject({
      _tag: 'MessageNotFound',
      id: 'missing-message',
    });
  });

  it('opening a mock message does not mutate read state', async () => {
    expect.hasAssertions();
    const runtime = ManagedRuntime.make(MockMailbox);
    try {
      const before = await runtime.runPromise(listInbox);
      await runtime.runPromise(readMessage('studio-review'));
      const after = await runtime.runPromise(listInbox);
      expect(after).toStrictEqual(before);
      expect(
        after.find((message) => message.id === 'studio-review')?.unread,
      ).toBe(true);
    } finally {
      await runtime.dispose();
    }
  });
});
