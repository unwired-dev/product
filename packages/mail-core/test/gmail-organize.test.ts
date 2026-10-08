import { setImmediate } from 'node:timers/promises';

import { english } from '@private-email/localization';

import type { GmailInboxState, GmailMessage } from '../src/gmail-inbox.ts';

import {
  gmailAction,
  gmailActionCopy,
  quickActions,
  restoreAfter,
} from '../src/gmail-actions.ts';
import { createGmailInbox } from '../src/gmail-inbox.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

const unsavedNotice = (state: GmailInboxState) => {
  const outcome = ready(state).notice;
  if (outcome?.kind !== 'unsaved') {
    throw new Error('Expected the unsaved batch outcome');
  }
  return outcome;
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

// The listing pages named by token wait until the test releases each one.
const holdingPages = (
  native: ReturnType<typeof createSyntheticGmail>['native'],
  tokens: readonly string[],
) => {
  const holds = tokens.map(() => ({
    entered: Promise.withResolvers<undefined>(),
    release: Promise.withResolvers<undefined>(),
  }));
  return {
    holds,
    native: {
      ...native,
      gmailRequest: async (...args: Parameters<typeof native.gmailRequest>) => {
        const [path, query] = args;
        const token = query.find(([name]) => name === 'pageToken')?.[1];
        const hold =
          path === 'messages' ? holds[tokens.indexOf(token ?? '')] : undefined;
        hold?.entered.resolve(undefined);
        await hold?.release.promise;
        return native.gmailRequest(...args);
      },
    },
  };
};

// Resolves when the Inbox publishes a state matching the predicate.
const until = (
  inbox: ReturnType<typeof createGmailInbox>,
  matches: (state: GmailInboxState) => boolean,
) => {
  const reached = Promise.withResolvers<undefined>();
  const unsubscribe = inbox.subscribe(() => {
    if (matches(inbox.getSnapshot())) {
      unsubscribe();
      reached.resolve(undefined);
    }
  });
  return reached.promise;
};

// The first message metadata read after `interruptRead()` fails as an interrupted connection.
const interruptingNextRead = (
  native: ReturnType<typeof createSyntheticGmail>['native'],
) => {
  let interrupt = false;
  return {
    interruptRead: () => {
      interrupt = true;
    },
    native: {
      ...native,
      gmailRequest: async (...args: Parameters<typeof native.gmailRequest>) => {
        if (interrupt && args[0].startsWith('messages/')) {
          interrupt = false;
          throw Object.assign(new Error('Synthetic interruption'), {
            code: 'unavailable',
          });
        }
        return native.gmailRequest(...args);
      },
    },
  };
};

// The next cache commit waits until the test releases it.
const holdingNextCommit = (
  native: ReturnType<typeof createSyntheticGmail>['native'],
) => {
  const hold = {
    entered: Promise.withResolvers<undefined>(),
    release: Promise.withResolvers<undefined>(),
  };
  let held = false;
  return {
    hold,
    native: {
      ...native,
      commitMailbox: async (
        ...args: Parameters<typeof native.commitMailbox>
      ) => {
        if (!held) {
          held = true;
          hold.entered.resolve(undefined);
          await hold.release.promise;
        }
        return native.commitMailbox(...args);
      },
    },
  };
};

// The cache opens as cache-only, as after an unverified relaunch, once switched.
const switchingToCacheOnly = (
  native: ReturnType<typeof createSyntheticGmail>['native'],
) => {
  let cacheOnly = false;
  return {
    becomeCacheOnly: () => {
      cacheOnly = true;
    },
    verify: () => {
      cacheOnly = false;
    },
    native: {
      ...native,
      openMailbox: async () => ({
        ...(await native.openMailbox()),
        ...(cacheOnly ? { availability: 'retry' } : {}),
      }),
    },
  };
};

// One change saved on this device and none still saving.
const oneDurableChange = (state: GmailInboxState) =>
  state.kind === 'ready' && state.pending === 1 && state.saving === 0;

const twoDurableChanges = (state: GmailInboxState) =>
  state.kind === 'ready' && state.pending === 2 && state.saving === 0;

const firstListingPage = ({
  path,
  query,
}: Readonly<{ path: string; query: URLSearchParams }>) =>
  path === 'messages' && query.get('pageToken') === null;

// Hold one write before its CAS check so independent intake can win the revision.
const holdingCommit = (
  native: ReturnType<typeof createSyntheticGmail>['native'],
) => {
  let writes = 0;
  let heldWrite = 0;
  const entered = Promise.withResolvers<undefined>();
  const release = Promise.withResolvers<undefined>();
  return {
    entered,
    release,
    arm: (ordinal: number) => {
      writes = 0;
      heldWrite = ordinal;
    },
    native: {
      ...native,
      commitMailbox: async (
        ...args: Parameters<typeof native.commitMailbox>
      ) => {
        writes += 1;
        if (writes === heldWrite) {
          entered.resolve(undefined);
          await release.promise;
        }
        return native.commitMailbox(...args);
      },
    },
  };
};

// Hold the first provider write before applying it; later writes use the real provider directly.
const holdingModify = (
  native: ReturnType<typeof createSyntheticGmail>['native'],
) => {
  const entered = Promise.withResolvers<undefined>();
  const release = Promise.withResolvers<undefined>();
  let held = false;
  return {
    entered,
    release,
    native: {
      ...native,
      gmailModify: async (...args: Parameters<typeof native.gmailModify>) => {
        if (!held) {
          held = true;
          entered.resolve(undefined);
          await release.promise;
        }
        return native.gmailModify(...args);
      },
    },
  };
};

/* oxlint-disable vitest/max-expects -- Each journey proves one organizing path end to end. */
// Holds a downloaded body and the removal prune reply, with later history interrupted so a
// second prune cannot conceal a late admission into the removed message's cache.
const holdingBodyAndRemoval = (
  gmail: ReturnType<typeof createSyntheticGmail>,
  id: string,
) => {
  const full = Promise.withResolvers<undefined>();
  const downloaded = Promise.withResolvers<undefined>();
  const pruning = Promise.withResolvers<undefined>();
  const finishPruning = Promise.withResolvers<undefined>();
  let holdPrune = false;
  let interruptHistory = false;
  const native = {
    ...gmail.native,
    gmailRequest: async (...args) => {
      const [path, query] = args;
      if (interruptHistory && path === 'history') {
        return { status: 503, body: '{}' };
      }
      const reply = await gmail.native.gmailRequest(...args);
      if (
        path === `messages/${id}` &&
        query.some(([name, value]) => name === 'format' && value === 'full')
      ) {
        downloaded.resolve(undefined);
        await full.promise;
      }
      return reply;
    },
    retainMessageBodies: async (...args) => {
      const reply = await gmail.native.retainMessageBodies(...args);
      if (holdPrune && !args[1].includes(id)) {
        holdPrune = false;
        pruning.resolve(undefined);
        await finishPruning.promise;
      }
      return reply;
    },
  } satisfies typeof gmail.native;
  return {
    native,
    full,
    downloaded,
    pruning,
    finishPruning,
    armRemoval: () => {
      holdPrune = true;
      interruptHistory = true;
    },
  };
};

describe('organizing Gmail mail', () => {
  it('isolates the label catalog after switching the synthetic mailbox', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const oldLabel = gmail.createLabel('First mailbox label');
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    expect(ready(inbox.getSnapshot()).labels).toStrictEqual([
      { id: oldLabel, name: 'First mailbox label' },
    ]);
    inbox.forget();
    gmail.reselect('second-labels@example.invalid');
    gmail.deliver({ subject: 'Second mailbox message' });
    await inbox.load();
    expect(ready(inbox.getSnapshot()).labels).toStrictEqual([]);
  });

  it('refuses a deleted label after a replacement is created', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const deleted = gmail.createLabel('Deleted label');
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the message',
    );
    gmail.failModify({ code: 'unavailable' });
    await inbox.organize(target, gmailAction.label(deleted));
    gmail.deleteLabel(deleted);
    const replacement = gmail.createLabel('Replacement label');
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({
      pending: 0,
      notice: { kind: 'rejected' },
    });
    expect(gmail.labelsOf(target.id)).not.toContain(replacement);
    expect(ready(inbox.getSnapshot()).labels).toStrictEqual([
      { id: replacement, name: 'Replacement label' },
    ]);
  });

  it('fences a late body admission while action reconciliation removes its message', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      at: 0,
      content: { text: 'Held readable body' },
    });
    const held = holdingBodyAndRemoval(gmail, id);
    const inbox = createGmailInbox(held.native);
    await inbox.load();
    const source = message(inbox, id);
    const reading = inbox.readMessage(id);
    await held.downloaded.promise;
    gmail.remove(id);
    held.armRemoval();
    const organizing = inbox.organize(source, gmailAction.star);
    await held.pruning.promise;
    held.full.resolve(undefined);
    // Drain the released transport response's promise continuations while native pruning is held.
    await setImmediate();
    held.finishPruning.resolve(undefined);
    await organizing;
    await reading;
    expect(ready(inbox.getSnapshot()).sync).toBe('retry');
    expect(shown(inbox, id)).toBeUndefined();
    expect(inbox.messageBody(id)).toBeUndefined();
    expect(gmail.cachedBodies().has(id)).toBe(false);
  });

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
    // The restore is announced too, and offers no Undo of its own.
    expect(ready(inbox.getSnapshot()).notice).toMatchObject({
      kind: 'done',
      action: { kind: 'restore' },
    });
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

  it('keeps the Inbox and every change when intake commits under each step of a listing', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 160 });
    // The second, third and fourth listing pages each wait for one tap to be saved first.
    const { native, holds } = holdingPages(gmail.native, ['50', '100', '150']);
    const inbox = createGmailInbox(native);
    // Earlier taps were sent before the listing reached its next page, so one change waits.
    const durable = () => until(inbox, oneDurableChange);
    // The storage failure screen must never appear, even if a later synchronization recovers.
    const shownKinds = new Set<GmailInboxState['kind']>();
    const stopWatching = inbox.subscribe(() => {
      shownKinds.add(inbox.getSnapshot().kind);
    });
    const listing = inbox.load();
    const starred: GmailMessage[] = [];
    const organizing: Array<Promise<void>> = [];
    for (const [index, hold] of holds.entries()) {
      await hold.entered.promise;
      const target = required(
        ready(inbox.getSnapshot()).messages[index],
        'a listed message',
      );
      starred.push(target);
      const saved = durable();
      organizing.push(inbox.organize(target, gmailAction.star));
      await saved;
      // The intake committed a newer revision under the waiting listing's next commit.
      hold.release.resolve(undefined);
    }
    await Promise.all([listing, ...organizing]);
    stopWatching();
    expect([...shownKinds]).not.toContain('failed');
    expect(ready(inbox.getSnapshot())).toMatchObject({
      sync: 'current',
      pending: 0,
    });
    expect(ready(inbox.getSnapshot()).messages).toHaveLength(160);
    for (const item of starred) {
      expect(gmail.labelsOf(item.id)).toContain('STARRED');
    }
    // The listing went on from each page instead of starting again.
    expect(gmail.requests.filter(firstListingPage)).toHaveLength(1);
  });

  it.each([
    { ordinal: 2, phase: 'prepare' },
    { ordinal: 3, phase: 'settle' },
  ] as const)(
    'keeps FIFO intent without resending the settled head when intake wins the $phase commit',
    async ({ ordinal }) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail({ messages: 1 });
      const held = holdingCommit(gmail.native);
      const inbox = createGmailInbox(held.native);
      await inbox.load();
      const target = required(
        ready(inbox.getSnapshot()).messages[0],
        'the message',
      );
      held.arm(ordinal);
      const first = inbox.organize(target, gmailAction.star);
      await held.entered.promise;
      const durable = until(inbox, twoDurableChanges);
      const second = inbox.organize(
        message(inbox, target.id),
        gmailAction.unstar,
      );
      await durable;
      held.release.resolve(undefined);
      await Promise.all([first, second]);
      expect(gmail.modifies).toStrictEqual([
        { id: target.id, add: ['STARRED'], remove: [] },
        { id: target.id, add: [], remove: ['STARRED'] },
      ]);
      expect(gmail.labelsOf(target.id)).not.toContain('STARRED');
      expect(ready(inbox.getSnapshot())).toMatchObject({
        pending: 0,
        saving: 0,
        sync: 'current',
      });
      await createGmailInbox(gmail.native).load();
      expect(gmail.modifies).toHaveLength(2);
    },
  );

  it('does not rebase an old mailbox intent onto a different mailbox opened after a conflict', async () => {
    expect.hasAssertions();
    const first = createSyntheticGmail({ messages: 1 });
    const second = createSyntheticGmail({
      address: 'second@example.invalid',
      messages: 1,
    });
    await createGmailInbox(second.native).load();
    const entered = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    let current = first;
    let writes = 0;
    let armed = false;
    let reopening = false;
    const inbox = createGmailInbox({
      ...first.native,
      openMailbox: async () => {
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Reselection happens while the conflict reopens its cache.
        if (reopening) {
          reopening = false;
          entered.resolve(undefined);
          await release.promise;
        }
        return current.native.openMailbox();
      },
      commitMailbox: (...args) => {
        writes += 1;
        // oxlint-disable-next-line vitest/no-conditional-in-test -- The prepare commit alone fails; intake is already durable.
        if (armed && writes === 2) {
          current.failCommit('conflict');
          reopening = true;
        }
        return current.native.commitMailbox(...args);
      },
      gmailRequest: (...args) => current.native.gmailRequest(...args),
      gmailModify: (...args) => current.native.gmailModify(...args),
      openMessageBody: (...args) => current.native.openMessageBody(...args),
      commitMessageBody: (...args) => current.native.commitMessageBody(...args),
      listMessageBodies: (...args) => current.native.listMessageBodies(...args),
      retainMessageBodies: (...args) =>
        current.native.retainMessageBodies(...args),
    });
    await inbox.load();
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the old mailbox message',
    );
    armed = true;
    writes = 0;
    const organizing = inbox.organize(target, gmailAction.star);
    await entered.promise;
    inbox.forget();
    current = second;
    const switched = inbox.load();
    release.resolve(undefined);
    await Promise.all([organizing, switched]);
    expect(first.modifies).toStrictEqual([]);
    expect(second.modifies).toStrictEqual([]);
    expect(ready(inbox.getSnapshot())).toMatchObject({
      address: 'second@example.invalid',
      pending: 0,
      saving: 0,
    });
    expect(
      second.commits.every((document) => !document.includes('"pending":[{')),
    ).toBe(true);
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
    const removed = vi.fn<() => void>();
    const inbox = createGmailInbox(
      {
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
      },
      { removed },
    );
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
    // Native code already deleted this device's data, so no storage failure claims it was kept;
    // the account page explains the removal.
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'loading' });
    expect(removed.mock.calls).toStrictEqual([[]]);
  });

  it('hands a removal found while opening the cache to the account page, from intake and synchronization', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const removed = vi.fn<() => void>();
    const inbox = createGmailInbox(gmail.native, { removed });
    await inbox.load();
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the message',
    );
    // The intake's cache preflight finds this device removed and native code purges it.
    gmail.failOpen('mailbox-revoked');
    await inbox.organize(target, gmailAction.star);
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'loading' });
    expect(removed.mock.calls).toStrictEqual([[]]);
    expect(gmail.modifies).toStrictEqual([]);
    // A synchronization opening the cache of a removed device hands over the same way.
    const relaunched = createGmailInbox(gmail.native, { removed });
    gmail.failOpen('mailbox-revoked');
    await relaunched.load();
    expect(relaunched.getSnapshot()).toStrictEqual({ kind: 'loading' });
    expect(removed.mock.calls).toStrictEqual([[], []]);
  });

  it('settles a refusal saved before an interrupted label read without sending it again', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const label = gmail.createLabel('Receipts');
    const { native, interruptRead } = interruptingNextRead(gmail.native);
    const inbox = createGmailInbox(native);
    await inbox.load();
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the message',
    );
    gmail.deleteLabel(label);
    // Gmail refuses the label for good, then the read of current labels is interrupted.
    interruptRead();
    await inbox.organize(target, gmailAction.label(label));
    expect(ready(inbox.getSnapshot()).sync).toBe('retry');
    // The next synchronization settles the saved refusal from Gmail's labels without a new write,
    // then reaches the later star, whose first attempt is interrupted too.
    gmail.failModify({ code: 'unavailable' });
    await inbox.organize(message(inbox, target.id), gmailAction.star);
    expect(
      gmail.modifies.filter(({ add }) => add.includes(label)),
    ).toHaveLength(1);
    expect(ready(inbox.getSnapshot())).toMatchObject({
      pending: 1,
      notice: { kind: 'rejected', action: { kind: 'label' } },
    });
    expect(message(inbox, target.id).labels).not.toContain(label);
    // A relaunch sends only the star.
    const relaunched = createGmailInbox(gmail.native);
    await relaunched.load();
    expect(ready(relaunched.getSnapshot()).pending).toBe(0);
    expect(gmail.labelsOf(target.id)).toContain('STARRED');
    expect(
      gmail.modifies.filter(({ add }) => add.includes(label)),
    ).toHaveLength(1);
  });

  it.each(['read', 'commit'] as const)(
    'does not carry a late refusal %s into another mailbox after forgetting its owner',
    async (held) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail();
      gmail.deliver({ subject: 'Private first-owner subject' });
      const label = gmail.createLabel('Receipts');
      const { native, interruptRead } = interruptingNextRead(gmail.native);
      let holdSettlement = false;
      const entered = Promise.withResolvers<undefined>();
      const released = Promise.withResolvers<undefined>();
      const inbox = createGmailInbox({
        ...native,
        gmailRequest: async (...args) => {
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Hold one old owner's already-completed read across mailbox reselection.
          if (
            // oxlint-disable-next-line vitest/no-conditional-in-test -- The controlled native-boundary hold applies to only the selected read case.
            holdSettlement &&
            held === 'read' &&
            args[0].startsWith('messages/')
          ) {
            holdSettlement = false;
            const reply = await native.gmailRequest(...args);
            entered.resolve(undefined);
            await released.promise;
            return reply;
          }
          return native.gmailRequest(...args);
        },
        commitMailbox: async (...args) => {
          const reply = await native.commitMailbox(...args);
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Hold the old owner's successful settlement reply across mailbox reselection.
          if (holdSettlement && held === 'commit') {
            holdSettlement = false;
            entered.resolve(undefined);
            await released.promise;
          }
          return reply;
        },
      });
      await inbox.load();
      const target = required(
        ready(inbox.getSnapshot()).messages[0],
        'the message',
      );
      gmail.deleteLabel(label);
      interruptRead();
      await inbox.organize(target, gmailAction.label(label));
      expect(ready(inbox.getSnapshot()).sync).toBe('retry');
      holdSettlement = true;
      const settling = inbox.load();
      await entered.promise;
      inbox.forget();
      gmail.reselect('second-owner@example.invalid');
      gmail.deliver({ subject: 'Second owner message' });
      const reopened = inbox.load();
      released.resolve(undefined);
      await Promise.all([settling, reopened]);
      expect(ready(inbox.getSnapshot())).toMatchObject({
        address: 'second-owner@example.invalid',
        pending: 0,
        messages: [{ subject: 'Second owner message' }],
      });
      expect(ready(inbox.getSnapshot()).notice).toBeUndefined();
      expect(
        gmail.modifies.filter(({ add }) => add.includes(label)),
      ).toHaveLength(1);
    },
  );

  it('keeps refusal feedback when durable settlement loses its reply', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const label = gmail.createLabel('Receipts');
    const { native, interruptRead } = interruptingNextRead(gmail.native);
    let loseReply = false;
    const inbox = createGmailInbox({
      ...native,
      commitMailbox: async (...args) => {
        const reply = await native.commitMailbox(...args);
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Interrupt one successful settlement reply after its durable native write.
        if (loseReply) {
          loseReply = false;
          throw Object.assign(new Error('Synthetic interruption'), {
            code: 'unavailable',
          });
        }
        return reply;
      },
    });
    await inbox.load();
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the message',
    );
    gmail.deleteLabel(label);
    interruptRead();
    await inbox.organize(target, gmailAction.label(label));
    expect(ready(inbox.getSnapshot()).sync).toBe('retry');
    loseReply = true;
    await inbox.load();
    expect(inbox.getSnapshot().kind).toBe('failed');
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({
      pending: 0,
      notice: { kind: 'rejected', action: { kind: 'label' } },
    });
    expect(
      gmail.modifies.filter(({ add }) => add.includes(label)),
    ).toHaveLength(1);
  });

  it('never resends a change another store instance settled while this one prepared it', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const first = createGmailInbox(gmail.native);
    await first.load();
    const target = required(
      ready(first.getSnapshot()).messages[0],
      'the message',
    );
    // The star waits after one interrupted attempt.
    gmail.failModify({ code: 'unavailable' });
    await first.organize(target, gmailAction.star);
    expect(ready(first.getSnapshot()).pending).toBe(1);
    // A second store instance prepares to send it again, and its preparation commit waits.
    const { native, hold } = holdingNextCommit(gmail.native);
    const second = createGmailInbox(native);
    const resending = second.load();
    await hold.entered.promise;
    // Meanwhile the first instance sends the star and settles it.
    await first.load();
    expect(ready(first.getSnapshot()).pending).toBe(0);
    hold.release.resolve(undefined);
    await resending;
    const stars = gmail.modifies.filter(({ add }) => add.includes('STARRED'));
    expect(stars).toHaveLength(2);
    expect(ready(second.getSnapshot())).toMatchObject({
      pending: 0,
      blocked: false,
    });
    expect(gmail.labelsOf(target.id)).toContain('STARRED');
  });

  it('keeps a competing preparation from landing after a later reversal', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const losingWrite = holdingModify(gmail.native);
    const preparation = holdingCommit(losingWrite.native);
    const first = createGmailInbox(preparation.native);
    await first.load();
    const target = required(
      ready(first.getSnapshot()).messages[0],
      'the message',
    );
    preparation.arm(2); // Intake is durable; its dispatch preparation waits before CAS.
    const organizing = first.organize(target, gmailAction.star);
    await preparation.entered.promise;

    const winningWrite = holdingModify(gmail.native);
    const second = createGmailInbox(winningWrite.native);
    const winning = second.load();
    await winningWrite.entered.promise;
    preparation.release.resolve(undefined);
    // Either the losing preparation exits or its duplicate reaches the controlled boundary.
    await Promise.race([organizing, losingWrite.entered.promise]);
    winningWrite.release.resolve(undefined);
    await winning;
    await second.organize(message(second, target.id), gmailAction.unstar);
    losingWrite.release.resolve(undefined);
    await organizing;
    await first.load();

    expect(gmail.labelsOf(target.id)).not.toContain('STARRED');
    expect(
      gmail.modifies.filter(({ add }) => add.includes('STARRED')),
    ).toHaveLength(1);
    expect(ready(second.getSnapshot()).pending).toBe(0);
    expect(ready(first.getSnapshot()).pending).toBe(0);
  });

  it('keeps a newly opened store from overtaking a live attempt', async () => {
    expect.hasAssertions();
    vi.useFakeTimers({ toFake: ['Date'] });
    const gmail = createSyntheticGmail({ messages: 1 });
    const held = holdingModify(gmail.native);
    const first = createGmailInbox(held.native);
    let organizing = Promise.resolve<unknown>(undefined);
    try {
      await first.load();
      const target = required(
        ready(first.getSnapshot()).messages[0],
        'the message',
      );
      organizing = first.organize(target, gmailAction.star);
      await held.entered.promise;
      const second = createGmailInbox(gmail.native);
      await second.load();
      await second.organize(message(second, target.id), gmailAction.unstar);
      held.release.resolve(undefined);
      await organizing;
      await second.load();
      await first.load();

      expect(gmail.labelsOf(target.id)).not.toContain('STARRED');
      expect(
        gmail.modifies.filter(({ add }) => add.includes('STARRED')),
      ).toHaveLength(1);
      expect(ready(first.getSnapshot()).pending).toBe(0);
      expect(ready(second.getSnapshot()).pending).toBe(0);
    } finally {
      held.release.resolve(undefined);
      await organizing;
      vi.useRealTimers();
    }
  });

  it('retries another live store’s completed failure immediately', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const first = createGmailInbox(gmail.native);
    const second = createGmailInbox(gmail.native);
    await first.load();
    await second.load();
    const target = required(
      ready(first.getSnapshot()).messages[0],
      'the message',
    );
    gmail.failModify({ code: 'unavailable' });
    await first.organize(target, gmailAction.star);
    for (let attempt = 1; attempt < 5; attempt += 1) {
      gmail.failModify({ code: 'unavailable' });
      await first.load();
    }
    await second.load();
    expect(ready(second.getSnapshot()).blocked).toBe(true);
    await second.resolvePending('retry');
    expect(gmail.labelsOf(target.id)).toContain('STARRED');
    expect(ready(second.getSnapshot())).toMatchObject({
      pending: 0,
      blocked: false,
    });
  });

  it('keeps a stale reconciliation from settling another store’s newer attempt', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const observed = Promise.withResolvers<undefined>();
    const releaseRead = Promise.withResolvers<undefined>();
    let holdRead = false;
    const first = createGmailInbox({
      ...gmail.native,
      gmailRequest: async (
        ...args: Parameters<typeof gmail.native.gmailRequest>
      ) => {
        const reply = await gmail.native.gmailRequest(...args);
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Capture one provider label reply before another store prepares a newer attempt.
        if (holdRead && args[0].startsWith('messages/')) {
          holdRead = false;
          observed.resolve(undefined);
          await releaseRead.promise;
        }
        return reply;
      },
    });
    await first.load();
    const target = required(
      ready(first.getSnapshot()).messages[0],
      'the message',
    );
    gmail.failModify({ code: 'unavailable' });
    await first.organize(target, gmailAction.star);
    gmail.setLabel(target.id, 'STARRED', true);
    holdRead = true;
    const reconciling = first.load();
    await observed.promise;
    gmail.setLabel(target.id, 'STARRED', false);
    const held = holdingModify(gmail.native);
    const second = createGmailInbox(held.native);
    const sending = second.load();
    try {
      await held.entered.promise;
      releaseRead.resolve(undefined);
      await reconciling;
      expect(ready(first.getSnapshot()).pending).toBe(1);
      await first.organize(message(first, target.id), gmailAction.unstar);
      expect(ready(first.getSnapshot()).pending).toBe(2);
      held.release.resolve(undefined);
      await sending;
      await first.load();
      expect(gmail.labelsOf(target.id)).not.toContain('STARRED');
      expect(ready(first.getSnapshot()).pending).toBe(0);
      expect(ready(second.getSnapshot()).pending).toBe(0);
    } finally {
      releaseRead.resolve(undefined);
      held.release.resolve(undefined);
      await reconciling;
      await sending;
    }
  });

  it('does not let Retry or Discard overtake an active fifth attempt', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const first = createGmailInbox(gmail.native);
    await first.load();
    const target = required(
      ready(first.getSnapshot()).messages[0],
      'the message',
    );
    gmail.failModify({ code: 'unavailable' });
    await first.organize(target, gmailAction.star);
    for (let attempt = 1; attempt < 4; attempt += 1) {
      gmail.failModify({ code: 'unavailable' });
      await first.load();
    }
    const held = holdingModify(gmail.native);
    const second = createGmailInbox(held.native);
    const sending = second.load();
    try {
      await held.entered.promise;
      await first.load();
      expect(ready(first.getSnapshot())).toMatchObject({
        pending: 1,
        blocked: false,
      });
      await first.resolvePending('retry');
      await first.resolvePending('discard');
      expect(ready(first.getSnapshot()).pending).toBe(1);
      await first.organize(message(first, target.id), gmailAction.unstar);
      held.release.resolve(undefined);
      await sending;
      await first.load();
      expect(gmail.labelsOf(target.id)).not.toContain('STARRED');
      expect(ready(first.getSnapshot()).pending).toBe(0);
    } finally {
      held.release.resolve(undefined);
      await sending;
    }
  });

  it('keeps later intent another store saves while this one settles a refused head', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 2 });
    const first = createGmailInbox(gmail.native);
    await first.load();
    const target = required(
      ready(first.getSnapshot()).messages[0],
      'the message',
    );
    const later = required(
      ready(first.getSnapshot()).messages[1],
      'the later message',
    );
    gmail.failModify({ code: 'unavailable' });
    await first.organize(target, gmailAction.star);

    const held = holdingCommit(gmail.native);
    held.arm(2); // Prepare succeeds; saving the provider refusal waits before CAS.
    const second = createGmailInbox(held.native);
    gmail.failModify({ status: 400 });
    const refusing = second.load();
    await held.entered.promise;
    // Another instance leaves the head to the store sending it and saves a different message's
    // read intent behind it.
    await first.load();
    gmail.failModify({ code: 'unavailable' });
    await first.organize(message(first, later.id), gmailAction.read);
    expect(ready(first.getSnapshot()).pending).toBe(2);
    held.release.resolve(undefined);
    await refusing;
    // The refused head settles; this store's first attempt of the read intent is interrupted, so
    // the other store can retry the read once the failed attempt has finished.
    expect(ready(second.getSnapshot())).toMatchObject({
      pending: 1,
      blocked: false,
    });
    expect(gmail.labelsOf(later.id)).toContain('UNREAD');
    await first.load();
    expect(gmail.labelsOf(later.id)).not.toContain('UNREAD');
    await second.load();

    expect(gmail.labelsOf(later.id)).not.toContain('UNREAD');
    expect(message(second, later.id).unread).toBe(false);
    expect(ready(second.getSnapshot())).toMatchObject({
      pending: 0,
      blocked: false,
    });
  });

  it('rolls back a change when the mailbox becomes cache-only before it could be saved', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const { native, becomeCacheOnly, verify } = switchingToCacheOnly(
      gmail.native,
    );
    const inbox = createGmailInbox(native);
    await inbox.load();
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the message',
    );
    expect(ready(inbox.getSnapshot()).organize).toBe(true);
    // Foreground verification found Gmail unreachable after the Inbox offered organizing.
    becomeCacheOnly();
    const commits = gmail.commits.length;
    const star = inbox.organize(target, gmailAction.star);
    const archive = inbox.organize(target, gmailAction.archive);
    await Promise.all([star, archive]);
    expect(ready(inbox.getSnapshot())).toMatchObject({
      organize: false,
      saving: 0,
      pending: 0,
      sync: 'retry',
    });
    expect(ready(inbox.getSnapshot()).notice).toMatchObject({
      kind: 'unsaved',
      count: 2,
      action: gmailAction.archive,
      message: target,
    });
    const outcome = unsavedNotice(inbox.getSnapshot());
    expect(gmailActionCopy(english, outcome)).toContain(
      '2 changes could not be saved',
    );
    expect(message(inbox, target.id).labels).not.toContain('STARRED');
    expect(gmail.commits).toHaveLength(commits);
    expect(gmail.modifies).toStrictEqual([]);
    // A retained handler cannot queue another change while only the saved Inbox opens.
    await inbox.organize(target, gmailAction.star);
    expect(ready(inbox.getSnapshot()).saving).toBe(0);
    // Reconnection does not replay a discarded change; the person explicitly repeats it.
    verify();
    await inbox.load();
    expect(ready(inbox.getSnapshot()).organize).toBe(true);
    expect(gmail.modifies).toStrictEqual([]);
    await inbox.organize(message(inbox, target.id), gmailAction.star);
    expect(gmail.labelsOf(target.id)).toContain('STARRED');
  });

  it('rolls back an unsaved change on load while preserving already durable intent', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const { native, becomeCacheOnly, verify } = switchingToCacheOnly(
      gmail.native,
    );
    const inbox = createGmailInbox(native);
    await inbox.load();
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'the message',
    );
    gmail.failModify({ code: 'unavailable' });
    await inbox.organize(target, gmailAction.star);
    expect(ready(inbox.getSnapshot()).pending).toBe(1);
    // This second request remains unsaved after storage locks; load must settle that queue first.
    gmail.failCommit('locked');
    await inbox.organize(message(inbox, target.id), gmailAction.archive);
    expect(inbox.getSnapshot().kind).toBe('locked');
    becomeCacheOnly();
    const requests = gmail.requests.length;
    const commits = gmail.commits.length;
    const modifies = gmail.modifies.length;
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({
      organize: false,
      saving: 0,
      pending: 1,
      sync: 'retry',
      notice: { kind: 'unsaved', count: 1, action: gmailAction.archive },
    });
    expect(message(inbox, target.id).labels).toContain('STARRED');
    expect(gmail.requests).toHaveLength(requests);
    expect(gmail.commits).toHaveLength(commits);
    expect(gmail.modifies).toHaveLength(modifies);
    // The durable Star survives a cache-only restart, then resumes without the unsaved Archive.
    const reopened = createGmailInbox(native);
    await reopened.load();
    expect(ready(reopened.getSnapshot()).pending).toBe(1);
    verify();
    await inbox.load();
    expect(ready(inbox.getSnapshot()).pending).toBe(0);
    expect(gmail.labelsOf(target.id).toSorted()).toStrictEqual(
      ['INBOX', 'UNREAD', 'STARRED'].toSorted(),
    );
  });

  it('does not carry an unsaved outcome from another mailbox into its cache-only Inbox', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const { native, becomeCacheOnly } = switchingToCacheOnly(gmail.native);
    const inbox = createGmailInbox(native);
    await inbox.load();
    const former = required(
      ready(inbox.getSnapshot()).messages[0],
      'the message',
    );
    gmail.reselect('another@example.invalid');
    const other = gmail.deliver({ subject: 'Another mailbox message' });
    await createGmailInbox(gmail.native).load();
    becomeCacheOnly();
    const modifies = gmail.modifies.length;
    await inbox.organize(former, gmailAction.star);
    expect(ready(inbox.getSnapshot())).toMatchObject({
      address: 'another@example.invalid',
      organize: false,
      pending: 0,
      saving: 0,
      sync: 'retry',
    });
    expect(ready(inbox.getSnapshot()).notice).toBeUndefined();
    expect(
      ready(inbox.getSnapshot()).messages.map(({ id }) => id),
    ).toStrictEqual([other]);
    expect(gmail.modifies).toHaveLength(modifies);
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
      ...firstNative,
      openMailbox: () => current.openMailbox(),
      commitMailbox: (...args) => current.commitMailbox(...args),
      gmailRequest: (...args) => current.gmailRequest(...args),
      gmailModify: (...args) => current.gmailModify(...args),
      openMessageBody: (...args) => current.openMessageBody(...args),
      commitMessageBody: (...args) => current.commitMessageBody(...args),
      listMessageBodies: (...args) => current.listMessageBodies(...args),
      retainMessageBodies: (...args) => current.retainMessageBodies(...args),
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
      ...first.native,
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
      openMessageBody: (scope, id) =>
        current.native.openMessageBody({ ...scope, generation: '0' }, id),
      commitMessageBody: (scope, id, admission) =>
        current.native.commitMessageBody(
          { ...scope, generation: '0' },
          id,
          admission,
        ),
      listMessageBodies: (scope, ids) =>
        current.native.listMessageBodies({ ...scope, generation: '0' }, ids),
      retainMessageBodies: (scope, ids, protectedIds) =>
        current.native.retainMessageBodies(
          { ...scope, generation: '0' },
          ids,
          protectedIds,
        ),
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

  it('keeps legacy pending intent without inventing labels that permit another move', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const earlier = createGmailInbox(gmail.native);
    await earlier.load();
    const original = required(
      ready(earlier.getSnapshot()).messages[0],
      'a message',
    );
    const travel = gmail.createLabel('Travel');
    gmail.setLabel(original.id, travel, true);
    gmail.setLabel(original.id, 'STARRED', true);
    const legacy = { ...original, labels: undefined };
    // The predecessor could save a read intent before legacy relisting finished. A real old-store
    // reproduction verifies this fixture; neither the cached message nor the intent knew labels.
    await gmail.native.commitMailbox(
      { address: 'alex@example.invalid', generation: '0' },
      gmail.commits.length,
      JSON.stringify({
        ...JSON.parse(String(gmail.commits.at(-1))),
        messages: [legacy],
        pending: [
          { id: 'legacy-read', action: gmailAction.read, message: legacy },
        ],
      }),
    );
    const { native, hold } = holdingNextCommit(gmail.native);
    const upgraded = createGmailInbox(native);
    const upgrading = upgraded.load();
    await hold.entered.promise;
    const projected = message(upgraded, original.id);
    expect(projected.unread).toBe(false);
    expect(projected.labels).toBeUndefined();
    expect(quickActions(english, projected)).toStrictEqual([]);
    const ignored = upgraded.organize(projected, gmailAction.move(travel));
    expect(ready(upgraded.getSnapshot())).toMatchObject({
      pending: 1,
      saving: 0,
    });
    expect(ready(upgraded.getSnapshot()).notice).toBeUndefined();
    await ignored;
    hold.release.resolve(undefined);
    await upgrading;
    expect(
      gmail.modifies.map(({ add, remove }) => [add, remove]),
    ).toStrictEqual([[[], ['UNREAD']]]);
    expect(gmail.labelsOf(original.id).toSorted()).toStrictEqual(
      ['INBOX', travel, 'STARRED'].toSorted(),
    );
    expect(message(upgraded, original.id)).toMatchObject({ unread: false });
    expect(
      quickActions(english, message(upgraded, original.id)),
    ).not.toStrictEqual([]);
    expect(ready(upgraded.getSnapshot())).toMatchObject({
      pending: 0,
      saving: 0,
    });
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
    const travel = gmail.createLabel('Travel');
    gmail.setLabel(newest, travel, true);
    // The listing that reads the labels waits, with the saved messages shown meanwhile.
    const { native, holds } = holdingPages(gmail.native, ['']);
    const [listingHold] = holds;
    const upgraded = createGmailInbox(native);
    const listings = gmail.requests.filter(
      ({ path }) => path === 'messages',
    ).length;
    const upgrading = upgraded.load();
    await listingHold?.entered.promise;
    // Without its labels, a message offers no actions: Undo of a move could not tell that it
    // already had the target label.
    const unlabeled = message(upgraded, newest);
    expect(unlabeled.labels).toBeUndefined();
    expect(quickActions(english, unlabeled)).toStrictEqual([]);
    const ignored = upgraded.organize(unlabeled, gmailAction.move(travel));
    expect(ready(upgraded.getSnapshot())).toMatchObject({
      pending: 0,
      saving: 0,
    });
    expect(ready(upgraded.getSnapshot()).notice).toBeUndefined();
    await ignored;
    listingHold?.release.resolve(undefined);
    await upgrading;
    expect(gmail.modifies).toStrictEqual([]);
    expect(quickActions(english, message(upgraded, newest))).not.toStrictEqual(
      [],
    );
    const { messages } = ready(upgraded.getSnapshot());
    expect(messages).toHaveLength(3);
    expect(messages.every(({ labels }) => labels !== undefined)).toBe(true);
    expect(messages[0]?.labels).toContain('STARRED');
    expect(
      gmail.requests.filter(({ path }) => path === 'messages'),
    ).toHaveLength(listings + 1);
    // A handler retaining the earlier snapshot cannot manufacture an Undo after hydration either.
    await upgraded.organize(unlabeled, gmailAction.move(travel));
    expect(ready(upgraded.getSnapshot()).notice).toBeUndefined();
    expect(gmail.modifies).toStrictEqual([]);
    // Fresh labels make Move and its Undo safe, including the pre-existing target membership.
    await upgraded.organize(
      message(upgraded, newest),
      gmailAction.move(travel),
    );
    const notice = required(ready(upgraded.getSnapshot()).notice, 'a notice');
    expect(notice.message.labels).toContain(travel);
    await upgraded.organize(
      notice.message,
      required(restoreAfter(notice.action, notice.message.labels), 'an undo'),
    );
    expect(gmail.labelsOf(newest)).toContain('INBOX');
    expect(gmail.labelsOf(newest)).toContain(travel);
    expect(gmail.labelsOf(newest)).toContain('STARRED');
    expect(ready(upgraded.getSnapshot()).pending).toBe(0);
  });
});
