import type { GmailInboxState, GmailMessage } from '../src/gmail-inbox.ts';

import { gmailAction, restoreAfter } from '../src/gmail-actions.ts';
import { createGmailInbox } from '../src/gmail-inbox.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

const shown = (inbox: ReturnType<typeof createGmailInbox>, id: string) =>
  ready(inbox.getSnapshot()).messages.find((message) => message.id === id);

const message = (
  inbox: ReturnType<typeof createGmailInbox>,
  id: string,
): GmailMessage => {
  const found = shown(inbox, id);
  if (found === undefined) {
    throw new Error(`Message ${id} is not in the Inbox`);
  }
  return found;
};

const required = <A>(value: A | null | undefined, name: string): A => {
  if (value === undefined || value === null) {
    throw new Error(`Expected ${name}`);
  }
  return value;
};

/* oxlint-disable vitest/max-expects -- Each journey proves one organizing path end to end. */
describe('organizing Gmail mail', () => {
  it('shows each change at once, keeps it through an outage and relaunch, and applies Gmail label semantics', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    for (let index = 0; index < 6; index += 1) {
      gmail.deliver({ subject: `Unread ${index}` });
    }
    const travel = gmail.createLabel('Travel');
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    expect(ready(inbox.getSnapshot()).labels).toStrictEqual([
      { id: travel, name: 'Travel' },
    ]);
    const [
      read = '',
      starred = '',
      labeled = '',
      moved = '',
      archived = '',
      spam = '',
    ] = ready(inbox.getSnapshot()).messages.map(({ id }) => id);

    // Gmail cannot be reached: the change shows at once and is saved before any request.
    gmail.failModify({ code: 'unavailable' });
    const reading = inbox.organize(message(inbox, read), gmailAction.read);
    expect(message(inbox, read).unread).toBe(false);
    expect(ready(inbox.getSnapshot())).toMatchObject({ saving: 1, pending: 0 });
    await reading;
    expect(ready(inbox.getSnapshot())).toMatchObject({
      sync: 'retry',
      pending: 1,
    });
    expect(message(inbox, read).unread).toBe(false);
    const saved = String(gmail.commits.at(-1));
    expect(JSON.parse(saved).pending[0].action.kind).toBe('read');
    expect(saved.split('"action":')).toHaveLength(2);
    expect(gmail.labelsOf(read)).toContain('UNREAD');

    // A relaunch sends the saved change once and Gmail's answer replaces it.
    const relaunched = createGmailInbox(gmail.native);
    await relaunched.load();
    expect(ready(relaunched.getSnapshot())).toMatchObject({
      sync: 'current',
      pending: 0,
    });
    expect(message(relaunched, read).unread).toBe(false);
    expect(gmail.labelsOf(read)).not.toContain('UNREAD');
    expect(gmail.modifies).toStrictEqual([
      { id: read, add: [], remove: ['UNREAD'] },
      { id: read, add: [], remove: ['UNREAD'] },
    ]);

    await relaunched.organize(message(relaunched, starred), gmailAction.star);
    await relaunched.organize(
      message(relaunched, labeled),
      gmailAction.label(travel),
    );
    await relaunched.organize(
      message(relaunched, moved),
      gmailAction.move(travel),
    );
    await relaunched.organize(
      message(relaunched, archived),
      gmailAction.archive,
    );
    await relaunched.organize(message(relaunched, spam), gmailAction.spam);
    expect(gmail.labelsOf(starred)).toContain('STARRED');
    expect(message(relaunched, starred).labels).toContain('STARRED');
    expect(message(relaunched, labeled).labels).toContain(travel);
    // Move to keeps every other label; archive only leaves the Inbox.
    expect(gmail.labelsOf(moved)).toStrictEqual(['UNREAD', travel]);
    expect(gmail.labelsOf(archived)).toStrictEqual(['UNREAD']);
    expect(gmail.labelsOf(spam)).toStrictEqual(['UNREAD', 'SPAM']);
    const ids = ready(relaunched.getSnapshot()).messages.map(({ id }) => id);
    expect(ids).toStrictEqual([read, starred, labeled]);
    expect(ready(relaunched.getSnapshot()).notice).toMatchObject({
      kind: 'done',
      action: gmailAction.spam,
    });
    // Nothing waits, and a relaunch shows the same Inbox from history alone.
    const again = createGmailInbox(gmail.native);
    await again.load();
    expect(
      ready(again.getSnapshot()).messages.map(({ id }) => id),
    ).toStrictEqual(ids);
    expect(ready(again.getSnapshot()).pending).toBe(0);
  });

  it('restores a trashed message after Gmail confirmed it and history removed it', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 3 });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const [, trashed = ''] = ready(inbox.getSnapshot()).messages.map(
      ({ id }) => id,
    );
    const trashing = inbox.organize(message(inbox, trashed), gmailAction.trash);
    expect(shown(inbox, trashed)).toBeUndefined();
    await trashing;
    await inbox.load();
    expect(gmail.labelsOf(trashed)).toStrictEqual(['TRASH']);
    const notice = required(ready(inbox.getSnapshot()).notice, 'a notice');
    expect(notice).toMatchObject({ kind: 'done', action: gmailAction.trash });
    const undo = required(restoreAfter(notice.action), 'an undo');
    expect(undo).toStrictEqual({
      kind: 'restore',
      add: ['INBOX'],
      remove: ['TRASH'],
    });
    // The message the notice kept returns at once, in its place.
    const restoring = inbox.organize(notice.message, undo);
    expect(ready(inbox.getSnapshot()).messages.map(({ id }) => id)[1]).toBe(
      trashed,
    );
    expect(ready(inbox.getSnapshot()).notice).toBeUndefined();
    await restoring;
    expect(gmail.labelsOf(trashed)).toStrictEqual(['INBOX']);
    expect(shown(inbox, trashed)).toMatchObject({ unread: false });
    const relaunched = createGmailInbox(gmail.native);
    await relaunched.load();
    expect(shown(relaunched, trashed)).toBeDefined();
  });

  it('reconciles refused, repeated and interrupted changes in order without losing later ones', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 3 });
    const receipts = gmail.createLabel('Receipts');
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const [first = '', second = '', third = ''] = ready(
      inbox.getSnapshot(),
    ).messages.map(({ id }) => id);

    // Three changes wait offline; Gmail then loses the label and the third message.
    gmail.failModify({ code: 'unavailable' });
    await inbox.organize(message(inbox, first), gmailAction.label(receipts));
    gmail.failModify({ code: 'unavailable' });
    await inbox.organize(message(inbox, first), gmailAction.star);
    gmail.failModify({ code: 'unavailable' });
    await inbox.organize(message(inbox, third), gmailAction.unread);
    expect(ready(inbox.getSnapshot()).pending).toBe(3);
    expect(message(inbox, first).labels).toStrictEqual(
      expect.arrayContaining([receipts, 'STARRED']),
    );
    gmail.deleteLabel(receipts);
    gmail.remove(third);

    await inbox.load();
    const settled = ready(inbox.getSnapshot());
    expect(settled.pending).toBe(0);
    // The refused label shows as Gmail has it; the later star still applied.
    expect(message(inbox, first).labels).not.toContain(receipts);
    expect(message(inbox, first).labels).toContain('STARRED');
    expect(gmail.labelsOf(first)).toContain('STARRED');
    expect(shown(inbox, third)).toBeUndefined();
    expect(settled.notice).toMatchObject({
      kind: 'rejected',
      action: { kind: 'unread' },
      message: { id: third },
    });
    expect(settled.labels).toStrictEqual([]);

    // Gmail applies a change but the response is lost: it is sent again, with the same result.
    gmail.failModify({ lost: true });
    await inbox.organize(message(inbox, second), gmailAction.archive);
    expect(gmail.labelsOf(second)).toStrictEqual([]);
    expect(ready(inbox.getSnapshot()).pending).toBe(1);
    expect(shown(inbox, second)).toBeUndefined();
    await inbox.load();
    expect(ready(inbox.getSnapshot()).pending).toBe(0);
    expect(gmail.labelsOf(second)).toStrictEqual([]);
    expect(gmail.modifies.filter(({ id }) => id === second)).toHaveLength(1);
    // A double tap is repeated intent: both requests leave the same labels.
    const twice = message(inbox, first);
    await Promise.all([
      inbox.organize(twice, gmailAction.archive),
      inbox.organize(twice, gmailAction.archive),
    ]);
    expect(ready(inbox.getSnapshot())).toMatchObject({
      pending: 0,
      messages: [],
    });
    expect(gmail.labelsOf(first)).toStrictEqual(['UNREAD', 'STARRED']);
    // Each offline attempt sent the oldest waiting change first: three attempts, the refused
    // label and the star once each, then both archives.
    expect(
      gmail.modifies.filter(({ id }) => id === first).map(({ add }) => add),
    ).toStrictEqual([
      [receipts],
      [receipts],
      [receipts],
      [receipts],
      ['STARRED'],
      [],
      [],
    ]);
  });

  it('keeps pending changes on top of external Gmail label changes until Gmail confirms them', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 2 });
    const family = gmail.createLabel('Family');
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const [first = '', second = ''] = ready(inbox.getSnapshot()).messages.map(
      ({ id }) => id,
    );
    // Labels changed in Gmail itself arrive through history.
    gmail.setLabel(first, 'STARRED', true);
    gmail.setLabel(first, family, true);
    gmail.markRead(second);
    await inbox.load();
    expect(message(inbox, first).labels).toStrictEqual(
      expect.arrayContaining(['STARRED', family]),
    );
    expect(message(inbox, second).unread).toBe(false);
    expect(ready(inbox.getSnapshot()).labels).toStrictEqual([
      { id: family, name: 'Family' },
    ]);

    // A waiting unstar shows over Gmail's star, and Gmail's other changes survive it.
    gmail.failModify({ code: 'unavailable' });
    await inbox.organize(message(inbox, first), gmailAction.unstar);
    expect(message(inbox, first).labels).not.toContain('STARRED');
    expect(gmail.labelsOf(first)).toContain('STARRED');
    gmail.setLabel(first, family, false);
    gmail.setLabel(first, 'IMPORTANT', true);
    await inbox.load();
    expect(gmail.labelsOf(first)).toStrictEqual(['INBOX', 'IMPORTANT']);
    expect(message(inbox, first).labels).toStrictEqual(['INBOX', 'IMPORTANT']);
    expect(ready(inbox.getSnapshot()).pending).toBe(0);
  });

  it('never sends a change to another mailbox or saves one before Gmail access verifies', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 2 });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const [first = ''] = ready(inbox.getSnapshot()).messages.map(
      ({ id }) => id,
    );

    // A change that could not be saved stays with the mailbox it was made in.
    gmail.failCommit('locked');
    await inbox.organize(message(inbox, first), gmailAction.archive);
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'locked' });
    gmail.reselect('other@example.invalid');
    gmail.deliver({ subject: 'Other mailbox' });
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({
      address: 'other@example.invalid',
      pending: 0,
    });
    expect(ready(inbox.getSnapshot()).messages).toHaveLength(1);
    expect(gmail.modifies).toStrictEqual([]);

    // Closing the Inbox forgets changes it had not saved.
    gmail.failCommit('locked');
    const [other = ''] = ready(inbox.getSnapshot()).messages.map(
      ({ id }) => id,
    );
    await inbox.organize(message(inbox, other), gmailAction.star);
    inbox.forget();
    await inbox.load();
    expect(ready(inbox.getSnapshot()).pending).toBe(0);
    expect(gmail.modifies).toStrictEqual([]);

    // The saved Inbox opened offline cannot record a change.
    const snapshot = await gmail.native.openMailbox();
    const offline = createGmailInbox({
      ...gmail.native,
      openMailbox: () =>
        Promise.resolve({ ...snapshot, availability: 'retry' }),
    });
    await offline.load();
    const commits = gmail.commits.length;
    await offline.organize(message(offline, other), gmailAction.archive);
    expect(ready(offline.getSnapshot())).toMatchObject({
      organize: false,
      pending: 0,
    });
    expect(shown(offline, other)).toBeDefined();
    expect(gmail.commits).toHaveLength(commits);
  });

  it('persists intent while history is blocked and recovers it after leaving the Inbox', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const entered = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const saved = Promise.withResolvers<undefined>();
    let hold = false;
    const inbox = createGmailInbox({
      ...gmail.native,
      gmailRequest: async (path, query, scope) => {
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Hold exactly one provider read.
        if (hold && path === 'history') {
          hold = false;
          entered.resolve(undefined);
          await release.promise;
        }
        return gmail.native.gmailRequest(path, query, scope);
      },
    });
    await inbox.load();
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the message',
    );
    hold = true;
    const syncing = inbox.load();
    await entered.promise;
    const unsubscribe = inbox.subscribe(() => {
      const state = inbox.getSnapshot();
      // oxlint-disable-next-line vitest/no-conditional-in-test -- Observe durable intake completion.
      if (state.kind === 'ready' && state.pending === 1 && state.saving === 0) {
        saved.resolve(undefined);
      }
    });
    const organizing = inbox.organize(target, gmailAction.archive);
    expect(ready(inbox.getSnapshot())).toMatchObject({
      saving: 1,
      pending: 0,
      messages: [],
    });
    await saved.promise;
    const cache = await gmail.native.openMailbox();
    expect(
      JSON.parse(required(cache.document, 'the cache')).pending,
    ).toHaveLength(1);
    expect(gmail.modifies).toStrictEqual([]);
    inbox.forget();
    release.resolve(undefined);
    await Promise.all([syncing, organizing]);
    unsubscribe();
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'loading' });
    const relaunched = createGmailInbox(gmail.native);
    await relaunched.load();
    expect(ready(relaunched.getSnapshot())).toMatchObject({
      pending: 0,
      messages: [],
    });
    expect(gmail.labelsOf(target.id)).not.toContain('INBOX');
  });

  it('keeps pre-existing labels when Undo restores a move', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const label = gmail.createLabel('Travel');
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the message',
    );
    await inbox.organize(target, gmailAction.label(label));
    await inbox.organize(message(inbox, target.id), gmailAction.move(label));
    const notice = required(ready(inbox.getSnapshot()).notice, 'the move');
    await inbox.organize(
      notice.message,
      required(restoreAfter(notice.action, notice.message.labels), 'Undo'),
    );
    expect(gmail.labelsOf(target.id)).toStrictEqual(
      expect.arrayContaining(['INBOX', 'UNREAD', label]),
    );
    expect(message(inbox, target.id).labels).toStrictEqual(
      expect.arrayContaining(['INBOX', 'UNREAD', label]),
    );
  });

  it('does not duplicate intent after an acknowledged native commit loses its reply', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    let loseReply = false;
    const inbox = createGmailInbox({
      ...gmail.native,
      commitMailbox: async (scope, revision, document) => {
        const result = await gmail.native.commitMailbox(
          scope,
          revision,
          document,
        );
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Lose one successful intake reply.
        if (loseReply) {
          loseReply = false;
          throw Object.assign(new Error('Synthetic failure'), {
            code: 'conflict',
          });
        }
        return result;
      },
    });
    await inbox.load();
    loseReply = true;
    gmail.failModify({ code: 'unavailable' });
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the message',
    );
    await inbox.organize(target, gmailAction.star);
    const cache = await gmail.native.openMailbox();
    expect(
      JSON.parse(required(cache.document, 'the cache')).pending,
    ).toHaveLength(1);
    expect(ready(inbox.getSnapshot())).toMatchObject({ pending: 1, saving: 0 });
    await createGmailInbox(gmail.native).load();
    expect(gmail.labelsOf(target.id)).toContain('STARRED');
  });

  it('retains ordered intents after five attempts until explicit retry or discard', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the message',
    );
    gmail.failModify(
      ...Array.from({ length: 5 }, () => ({ code: 'unavailable' })),
    );
    await inbox.organize(target, gmailAction.star);
    for (const ignored of [0, 1, 2, 3]) {
      void ignored;
      await inbox.load();
    }
    expect(ready(inbox.getSnapshot())).toMatchObject({
      pending: 1,
      blocked: true,
    });
    const relaunched = createGmailInbox(gmail.native);
    await relaunched.load();
    expect(gmail.modifies).toHaveLength(5);
    expect(ready(relaunched.getSnapshot())).toMatchObject({
      pending: 1,
      blocked: true,
    });
    await relaunched.organize(message(relaunched, target.id), gmailAction.read);
    expect(gmail.modifies).toHaveLength(5);
    expect(ready(relaunched.getSnapshot()).pending).toBe(2);
    await relaunched.resolvePending('discard');
    expect(ready(relaunched.getSnapshot())).toMatchObject({
      pending: 0,
      blocked: false,
    });
    expect(gmail.labelsOf(target.id)).not.toContain('STARRED');
    expect(gmail.labelsOf(target.id)).not.toContain('UNREAD');
    gmail.failModify(
      ...Array.from({ length: 5 }, () => ({ code: 'unavailable' })),
    );
    await relaunched.organize(message(relaunched, target.id), gmailAction.star);
    for (const ignored of [0, 1, 2, 3]) {
      void ignored;
      await relaunched.load();
    }
    await relaunched.resolvePending('retry');
    expect(ready(relaunched.getSnapshot())).toMatchObject({
      pending: 0,
      blocked: false,
    });
    expect(gmail.labelsOf(target.id)).toContain('STARRED');
  });

  it('hides revoked mail and derives refused action state from Gmail even when history fails', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const label = gmail.createLabel('Travel');
    let failHistory = false;
    const inbox = createGmailInbox({
      ...gmail.native,
      gmailRequest: async (path, query, scope) => {
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Interrupt history after authoritative refusal metadata.
        if (failHistory && path === 'history') {
          failHistory = false;
          throw Object.assign(new Error('Synthetic failure'), {
            code: 'unavailable',
          });
        }
        return gmail.native.gmailRequest(path, query, scope);
      },
    });
    await inbox.load();
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the message',
    );
    gmail.markRead(target.id);
    gmail.deleteLabel(label);
    // Refusal metadata succeeds, then history fails. The message still reflects Gmail's read state.
    failHistory = true;
    gmail.failModify({ status: 400 });
    await inbox.organize(target, gmailAction.label(label));
    expect(message(inbox, target.id).unread).toBe(false);
    expect(ready(inbox.getSnapshot()).notice).toMatchObject({
      kind: 'rejected',
    });
    gmail.failModify({ code: 'mailbox-revoked' });
    await inbox.organize(message(inbox, target.id), gmailAction.star);
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'failed' });
  });

  it('ignores a late durable save reply after another owner has opened the Inbox', async () => {
    expect.hasAssertions();
    const first = createSyntheticGmail();
    first.deliver({ subject: 'First owner' });
    const second = createSyntheticGmail();
    second.deliver({ subject: 'Second owner' });
    const entered = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    let hold = false;
    const firstNative = {
      ...first.native,
      openMailbox: async () => ({
        ...(await first.native.openMailbox()),
        owner: 'first-owner',
      }),
      commitMailbox: async (
        ...args: Parameters<typeof first.native.commitMailbox>
      ) => {
        const result = {
          ...(await first.native.commitMailbox(...args)),
          owner: 'first-owner',
        };
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Delay one acknowledged intake reply.
        if (hold) {
          hold = false;
          entered.resolve(undefined);
          await release.promise;
        }
        return result;
      },
    };
    const secondNative = {
      ...second.native,
      openMailbox: async () => ({
        ...(await second.native.openMailbox()),
        owner: 'second-owner',
      }),
      commitMailbox: async (
        ...args: Parameters<typeof second.native.commitMailbox>
      ) => ({
        ...(await second.native.commitMailbox(...args)),
        owner: 'second-owner',
      }),
    };
    let current = firstNative;
    const inbox = createGmailInbox({
      openMailbox: () => current.openMailbox(),
      commitMailbox: (...args) => current.commitMailbox(...args),
      gmailRequest: (...args) => current.gmailRequest(...args),
      gmailModify: (...args) => current.gmailModify(...args),
    });
    await inbox.load();
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the first message',
    );
    hold = true;
    const saving = inbox.organize(target, gmailAction.star);
    await entered.promise;
    inbox.forget();
    current = secondNative;
    await inbox.load();
    release.resolve(undefined);
    await saving;
    expect(
      ready(inbox.getSnapshot()).messages.map(({ subject }) => subject),
    ).toStrictEqual(['Second owner']);
    expect(second.modifies).toStrictEqual([]);
  });

  it('binds retained message handlers to the owner while allowing same-owner generation renewal', async () => {
    expect.hasAssertions();
    const first = createSyntheticGmail({ messages: 1 });
    const second = createSyntheticGmail({ messages: 1 });
    let current = first;
    let owner = 'first-owner';
    let generation = 'first-generation';
    const inbox = createGmailInbox({
      openMailbox: async () => ({
        ...(await current.native.openMailbox()),
        owner,
        generation,
      }),
      commitMailbox: async (scope, revision, document) => ({
        ...(await current.native.commitMailbox(
          { ...scope, generation: '0' },
          revision,
          document,
        )),
        owner,
        generation,
      }),
      gmailRequest: (path, query, scope) =>
        current.native.gmailRequest(path, query, { ...scope, generation: '0' }),
      gmailModify: (change, scope) =>
        current.native.gmailModify(change, { ...scope, generation: '0' }),
    });
    await inbox.load();
    const retained = required(
      ready(inbox.getSnapshot()).messages[0],
      'the first message',
    );
    generation = 'renewed-generation';
    await inbox.organize(retained, gmailAction.star);
    expect(first.labelsOf(retained.id)).toContain('STARRED');
    current = second;
    owner = 'second-owner';
    // Even a colliding generation and Gmail ID cannot transfer an old handler to another owner.
    await inbox.load();
    await inbox.organize(retained, gmailAction.archive);
    expect(second.modifies).toStrictEqual([]);
    expect(second.labelsOf(retained.id)).toContain('INBOX');
    await inbox.organize(message(inbox, retained.id), gmailAction.star);
    expect(second.labelsOf(retained.id)).toContain('STARRED');
  });

  it('lists a cache saved before labels were kept again, keeping its messages visible', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 3 });
    const earlier = createGmailInbox(gmail.native);
    await earlier.load();
    const [newest = ''] = ready(earlier.getSnapshot()).messages.map(
      ({ id }) => id,
    );
    // The same document as the earlier release wrote it, without message labels.
    const saved = String(gmail.commits.at(-1));
    expect(saved).toContain('"labels":[');
    await gmail.native.commitMailbox(
      { address: 'alex@example.invalid', generation: '0' },
      gmail.commits.length,
      saved.replaceAll(/,"labels":\[[^\]]*\]/gu, ''),
    );
    expect(gmail.commits.at(-1)).not.toContain('"labels"');
    gmail.setLabel(newest, 'STARRED', true);
    const upgraded = createGmailInbox(gmail.native);
    const listings = gmail.requests.filter(
      ({ path }) => path === 'messages',
    ).length;
    await upgraded.load();
    const { messages } = ready(upgraded.getSnapshot());
    expect(messages).toHaveLength(3);
    expect(messages.every(({ labels }) => labels !== undefined)).toBe(true);
    expect(messages[0]?.labels).toContain('STARRED');
    expect(
      gmail.requests.filter(({ path }) => path === 'messages'),
    ).toHaveLength(listings + 1);
  });
});
