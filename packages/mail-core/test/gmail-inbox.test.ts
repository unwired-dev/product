import { inspect } from 'node:util';

import type { GmailInboxState } from '../src/gmail-inbox.ts';

import {
  createGmailInbox,
  forgetMailOutsideInbox,
} from '../src/gmail-inbox.ts';
import { createRegistration } from '../src/registration.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

const listRequests = (gmail: ReturnType<typeof createSyntheticGmail>) =>
  gmail.requests.filter(({ path }) => path === 'messages');

describe('synchronizing a Gmail Inbox', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one synchronization path end to end. */
  it('lists the Inbox in pages and applies later changes incrementally after relaunch', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 120 });
    const latest = gmail.deliver({
      from: '"Chen, Maya" <maya@example.invalid>',
      subject: 'Studio review',
      snippet:
        'Bring the &quot;quiet&quot; layout &amp; your notes &#8212; it&#39;s ready',
    });
    const inbox = createGmailInbox(gmail.native);
    const published: GmailInboxState[] = [];
    inbox.subscribe(() => {
      published.push(inbox.getSnapshot());
    });
    await inbox.load();

    const synced = ready(inbox.getSnapshot());
    expect(synced).toMatchObject({
      address: 'alex@example.invalid',
      sync: 'current',
    });
    expect(synced.messages).toHaveLength(121);
    expect(synced.messages[0]).toStrictEqual({
      id: latest,
      threadId: latest,
      sender: 'Chen, Maya',
      address: 'maya@example.invalid',
      subject: 'Studio review',
      preview: 'Bring the "quiet" layout & your notes — it\'s ready',
      receivedAt: expect.stringMatching(/^2026-09-01T\d\d:\d\d:00\.000Z$/u),
      unread: true,
      labels: ['INBOX', 'UNREAD'],
    });
    // Each page reached the interface as it was committed, before the listing finished.
    expect(listRequests(gmail)).toHaveLength(3);
    expect(published).toContainEqual({
      kind: 'ready',
      address: 'alex@example.invalid',
      messages: synced.messages.slice(0, 50),
      sync: 'syncing',
      labels: [],
      pending: 0,
      saving: 0,
      blocked: false,
      organize: true,
    });
    // Every page was committed with the checkpoint that resumes after it.
    expect(gmail.commits.length).toBeGreaterThanOrEqual(4);

    gmail.deliver({ from: 'oliver@example.invalid', subject: 'New arrival' });
    const [, archived = '', read = '', removed = ''] = synced.messages.map(
      ({ id }) => id,
    );
    gmail.archive(archived);
    gmail.markRead(read);
    gmail.remove(removed);

    const relaunched = createGmailInbox(gmail.native);
    const opening = relaunched.load();
    await opening;
    const updated = ready(relaunched.getSnapshot());
    expect(updated.sync).toBe('current');
    expect(updated.messages).toHaveLength(120);
    expect(updated.messages[0]).toMatchObject({
      sender: 'oliver@example.invalid',
      address: 'oliver@example.invalid',
      subject: 'New arrival',
    });
    const ids = updated.messages.map(({ id }) => id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(ids).not.toContain(archived);
    expect(ids).not.toContain(removed);
    expect(updated.messages).toContainEqual(
      expect.objectContaining({ id: read, unread: false }),
    );
    // The relaunch read history only; it never listed the Inbox again.
    expect(listRequests(gmail)).toHaveLength(3);
  });

  it('fills the bounded Inbox when a listed message leaves before metadata arrives', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 300 });
    let disappeared = false;
    const inbox = createGmailInbox({
      ...gmail.native,
      gmailRequest: (path, query, mailbox) => {
        // oxlint-disable-next-line vitest/no-conditional-in-test -- The provider race occurs only at the first metadata read.
        if (!disappeared && path.startsWith('messages/')) {
          disappeared = true;
          gmail.archive(path.slice('messages/'.length));
        }
        return gmail.native.gmailRequest(path, query, mailbox);
      },
    });
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({ sync: 'current' });
    expect(ready(inbox.getSnapshot()).messages).toHaveLength(200);
    const relaunched = createGmailInbox(gmail.native);
    await relaunched.load();
    expect(ready(relaunched.getSnapshot()).messages).toHaveLength(200);
  });

  it('refills an unchanged newer entry when an older arrival masks a removal', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 201 });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const [{ id: newest } = { id: '' }] = ready(inbox.getSnapshot()).messages;
    gmail.remove(newest);
    const older = gmail.deliver({ at: 0, subject: 'Imported older mail' });
    await inbox.load();
    const { messages } = ready(inbox.getSnapshot());
    expect(messages).toHaveLength(200);
    expect(messages.map(({ id }) => id)).not.toContain(older);
    expect(messages.map(({ id }) => id)).toContain('101');
  });

  it('resumes an interrupted listing from its committed checkpoint without duplicates', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 120 });
    const inbox = createGmailInbox(gmail.native);
    // The connection drops on the second page, after the first was committed.
    gmail.failPage('50', { code: 'unavailable' });
    await inbox.load();
    const partial = ready(inbox.getSnapshot());
    expect(partial.sync).toBe('retry');
    expect(partial.messages).toHaveLength(50);

    await inbox.load();
    const resumed = ready(inbox.getSnapshot());
    expect(resumed.sync).toBe('current');
    expect(new Set(resumed.messages.map(({ id }) => id)).size).toBe(120);
    // The retry asked for the second page again, never the first.
    expect(
      listRequests(gmail).map(({ query }) => query.get('pageToken')),
    ).toStrictEqual([null, '50', '50', '100']);

    // A commit that fails leaves the previous checkpoint, so the change is applied once later.
    const arrived = gmail.deliver({
      subject: 'Arrived during a failed commit',
    });
    gmail.failCommit('unavailable');
    await inbox.load();
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'failed' });
    await inbox.load();
    const recovered = ready(inbox.getSnapshot());
    expect(recovered.messages).toHaveLength(121);
    expect(recovered.messages.filter(({ id }) => id === arrived)).toHaveLength(
      1,
    );

    const expired = createSyntheticGmail({ messages: 120 });
    const interrupted = createGmailInbox(expired.native);
    expired.failPage('50', { code: 'unavailable' });
    await interrupted.load();
    expired.failPage('50', { status: 400 });
    const relaunched = createGmailInbox(expired.native);
    await relaunched.load();
    expect(ready(relaunched.getSnapshot()).sync).toBe('current');
    expect(ready(relaunched.getSnapshot()).messages).toHaveLength(120);
  });

  it('lists again after Gmail expires the history, keeping cached mail visible', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 4 });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const [, ...kept] = ready(inbox.getSnapshot()).messages;
    const [left = ''] = ready(inbox.getSnapshot()).messages.map(({ id }) => id);
    gmail.expireHistory();
    gmail.archive(left);
    const arrived = gmail.deliver({ subject: 'Arrived while history expired' });

    const published: GmailInboxState[] = [];
    inbox.subscribe(() => {
      published.push(inbox.getSnapshot());
    });
    await inbox.load();
    const recovered = ready(inbox.getSnapshot());
    expect(recovered.sync).toBe('current');
    expect(recovered.messages.map(({ id }) => id)).toContain(arrived);
    expect(recovered.messages.map(({ id }) => id)).not.toContain(left);
    expect(recovered.messages).toHaveLength(4);
    // The cached messages stayed visible throughout the new listing.
    for (const state of published) {
      expect(state).toMatchObject({
        kind: 'ready',
        messages: expect.arrayContaining(kept),
      });
    }
    expect(listRequests(gmail)).toHaveLength(2);
  });

  it('keeps cached mail through authentication and retry states, and hides it when storage fails', async () => {
    expect.hasAssertions();
    const logged: unknown[] = [];
    for (const method of ['log', 'info', 'warn', 'error'] as const) {
      vi.spyOn(console, method).mockImplementation((...values) => {
        logged.push(...values);
      });
    }
    const gmail = createSyntheticGmail();
    gmail.deliver({
      from: 'Sealed Sender <sealed-address@example.invalid>',
      subject: 'sealed-subject',
      snippet: 'sealed-snippet',
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const cached = ready(inbox.getSnapshot()).messages;
    expect(cached).toHaveLength(1);

    for (const [failure, sync] of [
      [{ status: 401 }, 'authentication'],
      [{ code: 'gmail-unavailable' }, 'authentication'],
      [
        {
          status: 403,
          body: '{"error":{"errors":[{"reason":"insufficientPermissions"}]}}',
        },
        'authentication',
      ],
      [
        {
          status: 403,
          body: '{"error":{"errors":[{"reason":"rateLimitExceeded"}]}}',
        },
        'retry',
      ],
      [
        {
          status: 403,
          body: '{"error":{"errors":[{"reason":"dailyLimitExceeded"}]}}',
        },
        'retry',
      ],
      [{ status: 429 }, 'retry'],
      [{ status: 500 }, 'retry'],
      [{ code: 'unavailable' }, 'retry'],
      // Malformed provider data never reaches the cache.
      [
        { status: 200, body: '{"history":"sealed-snippet","historyId":7}' },
        'retry',
      ],
    ] as const) {
      gmail.fail(failure);
      await inbox.load();
      expect(inbox.getSnapshot()).toStrictEqual({
        kind: 'ready',
        address: 'alex@example.invalid',
        messages: cached,
        sync,
        labels: [],
        pending: 0,
        saving: 0,
        blocked: false,
        organize: true,
      });
    }
    await inbox.load();
    expect(ready(inbox.getSnapshot()).sync).toBe('current');

    gmail.failOpen('locked');
    await inbox.load();
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'locked' });
    gmail.failOpen('unavailable');
    await inbox.load();
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'failed' });
    // Without a connected mailbox, nothing is cached or shown.
    const disconnected = createGmailInbox(gmail.native);
    gmail.failOpen('gmail-unavailable');
    await disconnected.load();
    expect(disconnected.getSnapshot()).toStrictEqual({
      kind: 'ready',
      messages: [],
      sync: 'authentication',
      labels: [],
      pending: 0,
      saving: 0,
      blocked: false,
      organize: false,
    });
    await inbox.load();
    expect(ready(inbox.getSnapshot()).messages).toStrictEqual(cached);

    // A synchronization restarts after an invalidation, but not indefinitely.
    gmail.fail(
      { code: 'mailbox-invalidated' },
      { code: 'mailbox-invalidated' },
      { code: 'mailbox-invalidated' },
    );
    await inbox.load();
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'failed' });
    await inbox.load();
    gmail.deliver({ subject: 'Competing commit' });
    // Each commit rebases twice over a newer revision and the synchronization restarts twice, so
    // a conflict that never clears still ends as a failure.
    for (const ignored of Array.from({ length: 9 })) {
      void ignored;
      gmail.failCommit('conflict');
    }
    await inbox.load();
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'failed' });

    expect(inspect(logged, { depth: 10 })).not.toMatch(/sealed-|alex@/u);
    expect(logged).toStrictEqual(
      expect.arrayContaining([
        'status 500',
        'code unavailable',
        'invalid at history',
        'code conflict',
        'code mailbox-invalidated',
      ]),
    );
  });

  it('replaces stale bounded entries with the actual Inbox after history expires', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 400 });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const stale = ready(inbox.getSnapshot()).messages;
    expect(stale).toHaveLength(200);
    gmail.expireHistory();
    for (const message of stale) {
      gmail.archive(message.id);
    }
    await inbox.load();
    const actual = ready(inbox.getSnapshot());
    expect(actual.sync).toBe('current');
    expect(actual.messages).toHaveLength(200);
    expect(actual.messages.map(({ id }) => id)).not.toStrictEqual(
      expect.arrayContaining(stale.map(({ id }) => id)),
    );
    expect(new Set(actual.messages.map(({ id }) => id)).size).toBe(200);
    // Removing a cached entry must admit an unchanged older Inbox entry.
    const larger = createSyntheticGmail({ messages: 201 });
    const bounded = createGmailInbox(larger.native);
    await bounded.load();
    const [removed = ''] = ready(bounded.getSnapshot()).messages.map(
      ({ id }) => id,
    );
    expect(removed).not.toBe('');
    larger.remove(removed);
    await bounded.load();
    expect(ready(bounded.getSnapshot()).messages).toHaveLength(200);
    expect(
      ready(bounded.getSnapshot()).messages.map(({ id }) => id),
    ).not.toContain(removed);
  });

  it('preserves an unreadable persisted document without provider work or replacement writes', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const malformedDocument = JSON.stringify({
      version: 1,
      messages: 'private-mail',
    });
    const cache = await gmail.native.commitMailbox(
      { address: 'alex@example.invalid', generation: '0' },
      0,
      malformedDocument,
    );
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'failed' });
    expect(gmail.requests).toHaveLength(0);
    await expect(gmail.native.openMailbox()).resolves.toStrictEqual(cache);
    expect(gmail.commits).toStrictEqual([malformedDocument]);
  });

  it('rejects a stale synchronization commit after same-address mailbox reselection', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const inbox = createGmailInbox({
      ...gmail.native,
      commitMailbox: (mailbox, revision, document) => {
        gmail.reselect(mailbox.address);
        gmail.deliver({ subject: 'Replacement mailbox' });
        return gmail.native.commitMailbox(mailbox, revision, document);
      },
    });
    await inbox.load();
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'failed' });
    expect(gmail.commits).toHaveLength(0);
    await expect(gmail.native.openMailbox()).resolves.toMatchObject({
      revision: 0,
      document: null,
    });
    const replacement = createGmailInbox(gmail.native);
    await replacement.load();
    expect(
      ready(replacement.getSnapshot()).messages.map(({ subject }) => subject),
    ).toStrictEqual(['Replacement mailbox']);
  });

  it('opens a cache-only mailbox without using unverified provider access', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 2 });
    const live = createGmailInbox(gmail.native);
    await live.load();
    const cached = ready(live.getSnapshot()).messages;
    gmail.requests.length = 0;
    const commits = [...gmail.commits];
    const snapshot = await gmail.native.openMailbox();
    const offline = createGmailInbox({
      ...gmail.native,
      openMailbox: () =>
        Promise.resolve({ ...snapshot, availability: 'retry' }),
    });
    await offline.load();
    expect(offline.getSnapshot()).toStrictEqual({
      kind: 'ready',
      address: 'alex@example.invalid',
      messages: cached,
      sync: 'retry',
      labels: [],
      pending: 0,
      saving: 0,
      blocked: false,
      // Nothing can be saved before Gmail access verifies again.
      organize: false,
    });
    expect(gmail.requests).toHaveLength(0);
    expect(gmail.commits).toStrictEqual(commits);
  });

  it('clears saved mail when the mailbox changes between synchronization requests', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    let reselect = () => undefined;
    const inbox = createGmailInbox({
      ...gmail.native,
      gmailRequest: (path, query, mailbox) => {
        reselect();
        return gmail.native.gmailRequest(path, query, mailbox);
      },
    });
    await inbox.load();
    reselect = () => {
      gmail.reselect('new@example.invalid');
      gmail.deliver({ subject: 'New mailbox' });
      reselect = () => undefined;
    };
    const published: GmailInboxState[] = [];
    inbox.subscribe(() => {
      published.push(inbox.getSnapshot());
    });
    // The invalidated synchronization starts again for the selected mailbox only.
    await inbox.load();
    expect(inbox.getSnapshot()).toMatchObject({
      address: 'new@example.invalid',
      messages: [expect.objectContaining({ subject: 'New mailbox' })],
      sync: 'current',
    });
    expect(ready(inbox.getSnapshot()).messages).toHaveLength(1);
    expect(published).not.toContainEqual(
      expect.objectContaining({
        address: 'new@example.invalid',
        messages: expect.arrayContaining([
          expect.objectContaining({ subject: 'Synthetic message 0' }),
        ]),
      }),
    );
  });

  it('reconciles competing stores and never shows another mailbox cache', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 60 });
    const first = createGmailInbox(gmail.native);
    const second = createGmailInbox(gmail.native);
    await Promise.all([first.load(), second.load()]);
    gmail.deliver({ subject: 'After both' });
    await Promise.all([first.load(), second.load()]);
    for (const store of [first, second]) {
      const { messages } = ready(store.getSnapshot());
      expect(messages).toHaveLength(61);
      expect(new Set(messages.map(({ id }) => id)).size).toBe(61);
    }

    gmail.reselect('other@example.invalid');
    gmail.deliver({ subject: 'Only in the other mailbox' });
    await first.load();
    expect(ready(first.getSnapshot())).toMatchObject({
      address: 'other@example.invalid',
      messages: [{ subject: 'Only in the other mailbox' }],
      sync: 'current',
    });
  });

  it('forgets mail in memory when its account leaves, including a late synchronization result', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 2 });
    let snapshot: unknown = {
      kind: 'connected',
      productAccountId: 'account-a',
      signInProvider: 'google',
      providerSubject: 'subject-a',
      address: 'alex@example.invalid',
    };
    const unused = () => Promise.reject(new Error('Not used'));
    const registration = createRegistration({
      restore: () => Promise.resolve(snapshot),
      signIn: unused,
      authorizeGmail: unused,
      link: unused,
      confirmRecoveryKey: unused,
      recoverWithRecoveryKey: unused,
      approveEnrollment: unused,
      declineEnrollment: unused,
      revokeTrustedDevice: unused,
      refreshPrivateSync: unused,
      signOut: () => Promise.resolve({ kind: 'signed-out' }),
      deleteProductAccount: unused,
    });
    let release: () => void = () => undefined;
    let paused = false;
    const inbox = createGmailInbox({
      ...gmail.native,
      gmailRequest: async (path, query, mailbox) => {
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Only the paused history read is held.
        if (paused && path === 'history') {
          // oxlint-disable-next-line promise/avoid-new -- Hold the history response across sign-out.
          await new Promise<void>((resolve) => {
            release = resolve;
          });
        }
        return gmail.native.gmailRequest(path, query, mailbox);
      },
    });
    forgetMailOutsideInbox(registration, inbox);
    await registration.restore();
    await inbox.load();
    expect(ready(inbox.getSnapshot()).messages).toHaveLength(2);

    // Signing out forgets the mail at once; a synchronization still running cannot bring it back.
    paused = true;
    const running = inbox.load();
    await registration.signOut();
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'loading' });
    // Even a restart after the late native rejection must keep the signed-out mail forgotten.
    gmail.fail({ code: 'mailbox-invalidated' });
    paused = false;
    release();
    await running;
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'loading' });

    // Another Product Account connecting the same address starts from nothing in memory.
    snapshot = {
      kind: 'connected',
      productAccountId: 'account-b',
      signInProvider: 'google',
      providerSubject: 'subject-b',
      address: 'alex@example.invalid',
    };
    await registration.restore();
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'loading' });
  });

  it('restarts a synchronization a foreground restore invalidated, keeping the Inbox visible', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 60 });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const cached = ready(inbox.getSnapshot()).messages;
    gmail.deliver({ subject: 'Arrived during foreground verification' });
    const published: GmailInboxState[] = [];
    inbox.subscribe(() => {
      published.push(inbox.getSnapshot());
    });
    // Registration renewed the mailbox's native generation before the history update committed.
    gmail.failCommit('mailbox-invalidated');
    await inbox.load();
    const synced = ready(inbox.getSnapshot());
    expect(synced.sync).toBe('current');
    expect(new Set(synced.messages.map(({ id }) => id)).size).toBe(61);
    for (const state of published) {
      expect(state).toMatchObject({
        kind: 'ready',
        messages: expect.arrayContaining([...cached]),
      });
    }
  });
  /* oxlint-enable vitest/max-expects */
});
