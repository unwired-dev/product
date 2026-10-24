import { ok } from 'node:assert/strict';

import type { GmailInbox } from '@private-email/mail-core/gmail-inbox';
import type { ImapInbox } from '@private-email/mail-core/imap-inbox';
import type { ShownRows } from '@private-email/mail-core/mailboxes';

import { gmailAction } from '@private-email/mail-core/gmail-actions';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import {
  advanceRowMotion,
  motionIdentityOf,
  organizingWork,
  placeLeavingRows,
  restingRowMotion,
} from '@private-email/mail-core/mailboxes';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';

// Every store publication, including the intermediate ones a host may render separately.
const observe = (inbox: GmailInbox | ImapInbox) => {
  const shown = () => {
    const state = inbox.getSnapshot();
    ok(state.kind === 'ready', `Expected ready, received ${state.kind}`);
    const mailbox = { id: 'connection', inbox, state };
    return {
      sections: [
        {
          key: 'today',
          data: state.messages.map((message) => ({ mailbox, message })),
        },
      ],
      keyOf: motionIdentityOf,
      contentOf: ({ message }: Parameters<typeof motionIdentityOf>[0]) =>
        message,
      ...organizingWork([mailbox]),
      scope: [inbox],
      covered: false,
    };
  };
  let tracked = restingRowMotion(shown());
  const stop = inbox.subscribe(() => {
    tracked = advanceRowMotion(tracked, shown());
  });
  return {
    keys: () =>
      shown().sections.flatMap(({ data }) => data.map(motionIdentityOf)),
    state: () => tracked,
    // The rows finish moving, as a host's animations do.
    settle: () => {
      tracked = { ...tracked, leaving: [], returning: new Set() };
    },
    stop,
  };
};

const firstMessage = <M>(
  inbox: Readonly<{
    getSnapshot: () => Readonly<{ kind: string; messages?: readonly M[] }>;
  }>,
) => {
  const state = inbox.getSnapshot();
  ok(state.kind === 'ready');
  const [message] = state.messages ?? [];
  ok(message !== undefined);
  return message;
};

const keyOf = (key: string) => key;
const finished = (shown: ShownRows<string>): ShownRows<string> => ({
  ...shown,
  working: [],
});
// One mailbox's rows, keyed by message. Its organizing work is unfinished while an outcome
// concerns a message; `finished` shows the same outcome once the provider confirmed it.
const shownRows = (
  sections: ShownRows<string>['sections'],
  outcome: unknown,
  concerned: readonly string[] = [],
): ShownRows<string> => ({
  sections,
  keyOf,
  contentOf: keyOf,
  outcomes: [outcome],
  concerned: new Map(concerned.map((identity) => [identity, outcome])),
  working: concerned,
  scope: [],
  covered: false,
});

describe('organizing row continuity', () => {
  it('keeps synchronized message details when the row later leaves', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ subject: 'Read elsewhere' });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const motion = observe(inbox);
    try {
      gmail.setLabel(id, 'UNREAD', false);
      await inbox.load();
      await inbox.organize(firstMessage(inbox), gmailAction.archive);
      expect(
        motion.state().leaving.map(({ item }) => item.message.unread),
      ).toStrictEqual([false]);
    } finally {
      motion.stop();
      inbox.forget();
    }
  });

  it('keeps finished removals quiet when another client restores them or similar mail arrives', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const at = Date.UTC(2026, 9, 24, 9);
    const id = gmail.deliver({ subject: 'Repeated notification', at });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const motion = observe(inbox);
    try {
      await inbox.organize(firstMessage(inbox), gmailAction.archive);
      motion.settle();
      gmail.setLabel(id, 'INBOX', true);
      await inbox.load();
      expect([...motion.state().returning]).toStrictEqual([]);
      await inbox.organize(firstMessage(inbox), gmailAction.archive);
      motion.settle();
      gmail.deliver({ subject: 'Repeated notification', at });
      await inbox.load();
      expect([...motion.state().returning]).toStrictEqual([]);
      // Undo brings back only the archived message, not the one that looks the same.
      const state = inbox.getSnapshot();
      ok(state.kind === 'ready');
      ok(state.notice !== undefined);
      await inbox.organize(state.notice.message, {
        kind: 'restore',
        add: ['INBOX'],
        remove: [],
      });
      expect([...motion.state().returning]).toStrictEqual([
        `connection\n${id}`,
      ]);
    } finally {
      motion.stop();
      inbox.forget();
    }
  });

  it('returns a blocked Gmail change discarded after relaunch, with no notice to name it', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const target = firstMessage(inbox);
    gmail.failModify(
      ...Array.from({ length: 5 }, () => ({ code: 'unavailable' })),
    );
    try {
      await inbox.organize(target, gmailAction.archive);
      for (let attempt = 1; attempt < 5; attempt += 1) {
        await inbox.load();
      }
    } finally {
      inbox.forget();
    }
    const relaunched = createGmailInbox(gmail.native);
    await relaunched.load();
    const motion = observe(relaunched);
    try {
      const state = relaunched.getSnapshot();
      ok(state.kind === 'ready');
      expect(state.notice).toBeUndefined();
      await relaunched.resolvePending('discard');
      expect([...motion.state().returning]).toStrictEqual([
        `connection\n${target.id}`,
      ]);
    } finally {
      motion.stop();
      relaunched.forget();
    }
  });

  it('retires a confirmed removal while another message in its mailbox remains blocked', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ subject: 'Confirmed removal' });
    gmail.deliver({ subject: 'Blocked removal' });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const motion = observe(inbox);
    try {
      const state = inbox.getSnapshot();
      ok(state.kind === 'ready');
      const confirmed = state.messages.find((message) => message.id === id);
      const blocked = state.messages.find((message) => message.id !== id);
      ok(confirmed !== undefined);
      ok(blocked !== undefined);
      gmail.failModify({ code: 'unavailable' });
      await inbox.organize(confirmed, gmailAction.archive);
      // The provider confirms the first removal while the second remains unfinished.
      gmail.archive(id);
      gmail.failModify(
        ...Array.from({ length: 5 }, () => ({ code: 'unavailable' })),
      );
      await inbox.organize(blocked, gmailAction.archive);
      for (let attempt = 1; attempt < 5; attempt += 1) {
        await inbox.load();
      }
      motion.settle();
      gmail.setLabel(id, 'INBOX', true);
      await inbox.load();
      expect(motion.keys()).toContain(`connection\n${id}`);
      expect([...motion.state().returning]).toStrictEqual([]);
      // Clearing the old notice after Discard must not interrupt the restored row's entrance.
      await inbox.resolvePending('discard');
      expect([...motion.state().returning]).toStrictEqual([
        `connection\n${blocked.id}`,
      ]);
    } finally {
      motion.stop();
      inbox.forget();
    }
  });

  it('keeps one IMAP row through a completed Archive and an immediate Undo under a new UID', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Archive', ['archive']);
    imap.deliver('INBOX', { subject: 'Original' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const motion = observe(inbox);
    const [key] = motion.keys();
    ok(key !== undefined);
    const seen: string[][] = [];
    const stop = inbox.subscribe(() => {
      seen.push([
        ...motion.state().leaving.map((row) => row.key),
        ...motion.state().returning,
      ]);
    });
    try {
      await inbox.organize(firstMessage(inbox), {
        kind: 'archive',
        destination: 'Archive',
      });
      const archived = motion.state().leaving.map((row) => row.key);
      seen.length = 0;
      await inbox.undo();

      expect({
        archived,
        // Every publication of the Undo keeps the row moving, under its first key.
        stalled: seen.filter((keys) => !keys.includes(key)).length,
        returning: [...motion.state().returning],
        keys: motion.keys(),
        attributed: motion.state().attributed.size,
      }).toStrictEqual({
        archived: [key],
        stalled: 0,
        returning: [key],
        keys: [key],
        attributed: 0,
      });
      // The Undo published more than once, and the server gave the message a new UID.
      expect([seen.length > 1, firstMessage(inbox).uid > 1]).toStrictEqual([
        true,
        true,
      ]);
    } finally {
      stop();
      motion.stop();
      inbox.forget();
    }
  });

  it('returns an IMAP Undo after its destination refresh fails and another action drains', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Archive', ['archive']);
    imap.deliver('INBOX', { subject: 'Restored' });
    imap.deliver('INBOX', { subject: 'Unrelated' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const motion = observe(inbox);
    try {
      const state = inbox.getSnapshot();
      ok(state.kind === 'ready');
      const restored = state.messages.find(
        (message) => message.subject === 'Restored',
      );
      const unrelated = state.messages.find(
        (message) => message.subject === 'Unrelated',
      );
      ok(restored !== undefined);
      ok(unrelated !== undefined);
      const key = motionIdentityOf({
        mailbox: { id: 'connection', state },
        message: restored,
      });
      await inbox.organize(restored, {
        kind: 'archive',
        destination: 'Archive',
      });
      motion.settle();
      vi.spyOn(imap.native, 'imapSynchronize').mockRejectedValueOnce({
        code: 'offline',
      });
      await inbox.undo();
      await inbox.organize(unrelated, { kind: 'star' });
      await inbox.load();
      expect(motion.keys()).toContain(key);
      expect([...motion.state().returning]).toStrictEqual([key]);
      expect(motion.state().attributed.size).toBe(0);
    } finally {
      motion.stop();
      inbox.forget();
    }
  });

  it('retires an IMAP restoration the provider refuses instead of retrying its destination', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Archive', ['archive']);
    imap.deliver('INBOX', { subject: 'Not restored' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const motion = observe(inbox);
    try {
      await inbox.organize(firstMessage(inbox), {
        kind: 'archive',
        destination: 'Archive',
      });
      motion.settle();
      vi.spyOn(imap.native, 'imapModify').mockRejectedValueOnce({
        code: 'imap-rejected',
      });
      await inbox.undo();
      const state = inbox.getSnapshot();
      ok(state.kind === 'ready');
      expect(state.notice?.kind).toBe('rejected');
      expect(state.organizing).toBeUndefined();
      expect(motion.state().attributed.size).toBe(0);
    } finally {
      motion.stop();
      inbox.forget();
    }
  });

  it('moves only the rows an outcome concerns, never synchronization', () => {
    expect.hasAssertions();
    const resting = restingRowMotion(
      shownRows([{ key: 'today', data: ['a', 'b'] }], undefined),
    );
    const synchronized = advanceRowMotion(
      resting,
      shownRows([{ key: 'today', data: ['new', 'b'] }], undefined),
    );
    const archived = advanceRowMotion(
      synchronized,
      shownRows([{ key: 'today', data: ['new'] }], 'archived b', ['b']),
    );

    expect([
      synchronized.leaving.length,
      [...synchronized.returning],
      archived.leaving.map(({ key }) => key),
      [...archived.returning],
    ]).toStrictEqual([0, [], ['b'], []]);
  });

  it('returns a message the server moves back after its notice, beside unrelated arrivals', () => {
    expect.hasAssertions();
    const resting = restingRowMotion(
      shownRows([{ key: 'today', data: ['x', 'y'] }], undefined),
    );
    const archived = advanceRowMotion(
      resting,
      shownRows([{ key: 'today', data: ['y'] }], 'archived x', ['x']),
    );
    // The restore notice publishes before the server's refreshed Inbox.
    const undone = advanceRowMotion(
      archived,
      shownRows([{ key: 'today', data: ['y'] }], 'restored x', ['x']),
    );
    const refreshed = advanceRowMotion(
      undone,
      shownRows([{ key: 'today', data: ['x', 'other', 'y'] }], 'restored x', [
        'x',
      ]),
    );

    expect([
      undone.leaving.map(({ key }) => key),
      [...refreshed.returning],
    ]).toStrictEqual([['x'], ['x']]);
  });

  it('keeps a finished removal quiet when its message comes back without an Undo', () => {
    expect.hasAssertions();
    const archived = advanceRowMotion(
      restingRowMotion(
        shownRows([{ key: 'today', data: ['a', 'b'] }], undefined),
      ),
      shownRows([{ key: 'today', data: ['b'] }], 'archived a', ['a']),
    );
    const confirmed = advanceRowMotion(
      { ...archived, leaving: [] },
      finished(shownRows([{ key: 'today', data: ['b'] }], 'archived a', ['a'])),
    );
    const restoredElsewhere = advanceRowMotion(
      confirmed,
      finished(
        shownRows([{ key: 'today', data: ['a', 'b'] }], 'archived a', ['a']),
      ),
    );
    // Withdrawn while unfinished, the same removal returns its row.
    const withdrawn = advanceRowMotion(
      { ...archived, leaving: [] },
      shownRows([{ key: 'today', data: ['a', 'b'] }], undefined),
    );

    expect([
      [...confirmed.attributed.keys()],
      [...restoredElsewhere.returning],
      [...withdrawn.returning],
    ]).toStrictEqual([[], [], ['a']]);
  });

  it('returns a blocked change discarded after relaunch, with no notice to name it', () => {
    expect.hasAssertions();
    // A relaunched store lists the blocked archive without its message and names it only there.
    const relaunched = restingRowMotion(
      shownRows([{ key: 'today', data: ['y'] }], undefined, ['x']),
    );
    const discarded = advanceRowMotion(
      relaunched,
      shownRows([{ key: 'today', data: ['x', 'y'] }], undefined),
    );
    const delivered = advanceRowMotion(
      discarded,
      shownRows([{ key: 'today', data: ['z', 'x', 'y'] }], undefined),
    );

    expect([[...discarded.returning], [...delivered.returning]]).toStrictEqual([
      ['x'],
      ['x'],
    ]);
  });

  it('retires returning motion when synchronization removes its row before the animation settles', () => {
    expect.hasAssertions();
    const removed = advanceRowMotion(
      restingRowMotion(
        shownRows([{ key: 'today', data: ['b'] }], 'archived', ['a', 'b']),
      ),
      shownRows([{ key: 'today', data: ['a', 'b'] }], 'undone', ['a', 'b']),
    );
    const synchronized = advanceRowMotion(
      removed,
      finished(
        shownRows([{ key: 'today', data: ['b'] }], 'undone', ['a', 'b']),
      ),
    );

    const arrivedAgain = advanceRowMotion(
      synchronized,
      finished(
        shownRows([{ key: 'today', data: ['a', 'b'] }], 'undone', ['a', 'b']),
      ),
    );
    expect([
      [...removed.returning],
      [...synchronized.returning],
      synchronized.leaving,
      [...arrivedAgain.returning],
    ]).toStrictEqual([['a'], [], [], []]);
  });

  it('finishes rows still leaving on a new outcome, except the one it brings back', () => {
    expect.hasAssertions();
    const rows = (data: readonly string[]) => [{ key: 'today', data }];
    const first = advanceRowMotion(
      restingRowMotion(shownRows(rows(['a', 'b', 'c']), undefined)),
      shownRows(rows(['b', 'c']), 'archived a', ['a']),
    );
    const second = advanceRowMotion(
      first,
      shownRows(rows(['c']), 'archived b', ['b']),
    );
    const undone = advanceRowMotion(
      second,
      shownRows(rows(['c']), 'restored b', ['b']),
    );

    expect([
      second.leaving.map(({ key }) => key),
      undone.leaving.map(({ key }) => key),
    ]).toStrictEqual([['b'], ['b']]);
  });

  it('does not rearm a present message from an old notice when another mailbox has an outcome', () => {
    expect.hasAssertions();
    const rows = [{ key: 'today', data: ['a', 'b'] }];
    const old = { message: 'a' };
    const other = { message: 'b' };
    const shown = {
      ...shownRows(rows, old),
      outcomes: [old, undefined],
      concerned: new Map([['a', old]]),
    };
    const changed = {
      ...shown,
      outcomes: [old, other],
      concerned: new Map([
        ['a', old],
        ['b', other],
      ]),
    };
    const notified = advanceRowMotion(restingRowMotion(shown), changed);
    const synchronized = advanceRowMotion(notified, {
      ...changed,
      sections: [{ key: 'today', data: ['b'] }],
    });

    expect(synchronized.leaving).toStrictEqual([]);
    // A later action on that same message still owns its removal.
    const next = { message: 'a' };
    const again = advanceRowMotion(notified, {
      ...changed,
      sections: [{ key: 'today', data: ['b'] }],
      outcomes: [next, other],
      concerned: new Map([
        ['a', next],
        ['b', other],
      ]),
    });
    expect(again.leaving.map(({ key }) => key)).toStrictEqual(['a']);
  });

  it('tracks a midnight section change even when the row order stays the same', () => {
    expect.hasAssertions();
    const shown = shownRows(
      [{ key: 'yesterday', data: ['a', 'b'] }],
      undefined,
    );
    const midnight = advanceRowMotion(
      restingRowMotion(
        shownRows([{ key: 'today', data: ['a', 'b'] }], undefined),
      ),
      shown,
    );
    const archived = shownRows(
      [{ key: 'yesterday', data: ['b'] }],
      'archived',
      ['a'],
    );
    const removed = advanceRowMotion(midnight, archived);

    expect(
      placeLeavingRows(archived.sections, removed.leaving, keyOf),
    ).toStrictEqual(shown.sections);
    expect(advanceRowMotion(midnight, shown)).toBe(midnight);
  });

  it('preserves section identity and order when an outcome removes adjacent rows and whole date sections', () => {
    expect.hasAssertions();
    const sections = [
      { key: 'today', data: ['a', 'b', 'c'] },
      { key: 'yesterday', data: ['d'] },
      { key: 'earlier', data: ['e', 'f'] },
    ];
    const moved = ['b', 'c', 'd', 'e', 'f'];
    const shown = shownRows([{ key: 'today', data: ['a'] }], 'archived', moved);
    const removed = advanceRowMotion(
      restingRowMotion(shownRows(sections, undefined)),
      shown,
    );

    expect(
      placeLeavingRows(shown.sections, removed.leaving, keyOf),
    ).toStrictEqual(sections);
    expect([
      ...advanceRowMotion(removed, shownRows(sections, 'undone', moved))
        .returning,
    ]).toStrictEqual(['b', 'c', 'd', 'e', 'f']);
    // Changing mailbox, query or Filter is a replacement even if its notice also differs.
    expect(
      advanceRowMotion(removed, {
        ...shown,
        scope: ['another view'],
        sections: [{ key: 'today', data: ['z'] }],
        outcomes: ['another mailbox notice'],
      }),
    ).toMatchObject({ leaving: [], returning: new Set() });
  });
});
