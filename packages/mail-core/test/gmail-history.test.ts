import { setTimeout } from 'node:timers/promises';

import type { GmailInboxState } from '@private-email/mail-core/gmail-inbox';

import { allMail, gmailAction } from '@private-email/mail-core/gmail-actions';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';

import { withNativeHistory } from './native-history-store.ts';

const createGmail = () => withNativeHistory(createSyntheticGmail());

type Inbox = ReturnType<typeof createGmailInbox>;
type Gmail = ReturnType<typeof createSyntheticGmail>;

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

// The messages a view shows; the Inbox is its own list.
const shown = (inbox: Inbox, label: string) => {
  const state = ready(inbox.getSnapshot());
  return label === 'INBOX'
    ? state.messages
    : (state.views?.find((view) => view.label === label)?.messages ?? []);
};

const ids = (messages: ReadonlyArray<Readonly<{ id: string }>>) =>
  messages.map(({ id }) => id);

// A mailbox whose oldest `archived` of `count` messages left the Inbox, so All Mail holds more
// than the Inbox does. Returns the IDs newest first, as Gmail lists them.
const mailbox = (gmail: Gmail, count: number, archived: number) => {
  const delivered = Array.from({ length: count }, (_, index) =>
    gmail.deliver({ subject: `Message ${index}`, unread: index % 2 === 0 }),
  );
  for (const id of delivered.slice(0, archived)) {
    gmail.archive(id);
  }
  return delivered.toReversed();
};

const backfilled = async (inbox: Inbox) => {
  await vi.waitFor(
    () => {
      expect(ready(inbox.getSnapshot()).history?.complete).toBe(true);
    },
    { timeout: 60_000 },
  );
};

// Scrolls a view to its end, asking for older mail until it shows `count` messages.
const scrolled = async (inbox: Inbox, label: string, count: number) => {
  while (shown(inbox, label).length < count) {
    const before = shown(inbox, label).length;
    inbox.showOlder(label);
    await vi.waitFor(() => {
      expect(shown(inbox, label).length).toBeGreaterThan(before);
    });
  }
};

// The All Mail pages Historical Metadata Backfill asked Gmail for, by page token.
const historyPages = (gmail: Gmail) =>
  gmail.requests
    .filter(
      ({ path, query }) =>
        path === 'messages' &&
        !query.has('labelIds') &&
        !query.has('q') &&
        query.get('maxResults') === '100',
    )
    .map(({ query }) => query.get('pageToken') ?? '');

// The mailbox document the device saved last.
const saved = (gmail: Gmail) => gmail.commits.at(-1) ?? '';

// Every message ID the saved mailbox document names outside its history segments.
const savedIds = (gmail: Gmail) =>
  [...saved(gmail).matchAll(/"id":"(?<id>[0-9a-f]+)"/gu)].map(
    ({ groups }) => groups?.id,
  );

const at = <T>(messages: readonly T[], index: number) => {
  const id = messages.at(index);
  if (id === undefined) {
    throw new Error(`Expected a message at ${index}`);
  }
  return id;
};

// Holds Historical Metadata Backfill's All Mail pages until released; the All Mail view lists
// its newest messages in smaller pages, so it keeps going.
const holdingHistory = (gmail: Gmail) => {
  const listing = Promise.withResolvers<undefined>();
  const reached = Promise.withResolvers<undefined>();
  let holding = false;
  const native: Gmail['native'] = {
    ...gmail.native,
    gmailRequest: async (path, query, request) => {
      if (
        holding &&
        path === 'messages' &&
        query.some(
          ([name, value]) => name === 'maxResults' && value === '100',
        ) &&
        query.every(([name]) => name !== 'labelIds' && name !== 'q')
      ) {
        reached.resolve(undefined);
        await listing.promise;
      }
      return gmail.native.gmailRequest(path, query, request);
    },
  };
  return {
    native,
    reached: reached.promise,
    hold: () => {
      holding = true;
    },
    release: () => {
      holding = false;
      listing.resolve(undefined);
    },
  };
};

// Mail received in the last hour, so recent-body prefetch selects it. Returns the IDs newest first.
const recentMailbox = (gmail: Gmail, count: number) => {
  const now = Date.now();
  return Array.from({ length: count }, (_, index) =>
    gmail.deliver({
      subject: `Recent ${index}`,
      at: now - (count - index) * 60_000,
    }),
  ).toReversed();
};

// Holds recent-body prefetch's first metadata request until released.
const holdingPrefetch = (gmail: Gmail) => {
  const metadata = Promise.withResolvers<undefined>();
  const reached = Promise.withResolvers<undefined>();
  const native: Gmail['native'] = {
    ...gmail.native,
    gmailRequest: async (path, query, request) => {
      // Finish synchronization only once prefetch owns the speculative lane.
      if (path === 'labels') {
        await reached.promise;
      }
      if (
        query.some(
          ([name, value]) =>
            name === 'metadataHeaders' && value === 'Content-Type',
        )
      ) {
        reached.resolve(undefined);
        await metadata.promise;
      }
      return gmail.native.gmailRequest(path, query, request);
    },
  };
  return {
    native,
    reached: reached.promise,
    release: () => {
      metadata.resolve(undefined);
    },
  };
};

const recordingSyncPages = (gmail: Gmail, native: Gmail['native']) => {
  const pages: number[] = [];
  return {
    pages,
    native: {
      ...native,
      gmailRequest: (
        ...[path, query, request]: Parameters<Gmail['native']['gmailRequest']>
      ) => {
        if (path === 'history') {
          pages.push(historyPages(gmail).length);
        }
        return native.gmailRequest(path, query, request);
      },
    },
  };
};

const holdingBody = (native: Gmail['native'], id: string) => {
  const body = Promise.withResolvers<undefined>();
  const reached = Promise.withResolvers<undefined>();
  return {
    reached: reached.promise,
    release: () => {
      body.resolve(undefined);
    },
    native: {
      ...native,
      gmailRequest: async (
        ...[path, query, request]: Parameters<Gmail['native']['gmailRequest']>
      ) => {
        if (
          path === `messages/${id}` &&
          query.some(([name, value]) => name === 'format' && value === 'full')
        ) {
          reached.resolve(undefined);
          await body.promise;
        }
        return native.gmailRequest(path, query, request);
      },
    },
  };
};

// A provider action settles, but the following history read cannot refresh older segments.
const withoutHistoryAfterOrganizing = (gmail: Gmail, deleted: boolean) => {
  let refuseHistory = false;
  return {
    ...gmail.native,
    gmailModify: async (
      ...args: Parameters<Gmail['native']['gmailModify']>
    ) => {
      if (deleted) {
        gmail.remove(args[0].message);
      }
      const reply = await gmail.native.gmailModify(...args);
      refuseHistory = true;
      return reply;
    },
    gmailRequest: (
      ...[path, query, request]: Parameters<Gmail['native']['gmailRequest']>
    ) =>
      path === 'history' && refuseHistory
        ? Promise.reject(new Error('Controlled history outage'))
        : gmail.native.gmailRequest(path, query, request),
  };
};

// A mailbox with spam whose history is downloaded, and the All Mail IDs newest first.
const downloaded = async () => {
  const gmail = createGmail();
  const everything = mailbox(gmail, 1000, 700);
  const spam = everything.slice(-5);
  for (const id of spam) {
    gmail.setLabel(id, 'SPAM', true);
  }
  const inbox = createGmailInbox(gmail.native);
  await inbox.load();
  return {
    gmail,
    inbox,
    everything,
    allMailIds: everything.filter((id) => !spam.includes(id)),
  };
};

describe('gmail history backfill', () => {
  it('reveals older messages sharing the cached boundary timestamp', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = Array.from({ length: 400 }, () =>
      gmail.deliver({ at: 1_700_000_000_000 }),
    )
      .toSorted()
      .toReversed();
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await backfilled(inbox);
    await scrolled(inbox, 'INBOX', 400);
    expect(ids(shown(inbox, 'INBOX'))).toStrictEqual(everything);
  });

  it('recovers from a failed history read when scrolling again', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    mailbox(gmail, 400, 0);
    const read = vi
      .fn<Gmail['native']['openMailboxSegment']>()
      .mockImplementation(gmail.native.openMailboxSegment)
      .mockRejectedValueOnce({ code: 'unavailable' });
    const inbox = createGmailInbox({
      ...gmail.native,
      openMailboxSegment: read,
    });
    await inbox.load();
    await backfilled(inbox);
    inbox.showOlder('INBOX');
    await vi.waitFor(() => {
      expect(read).toHaveBeenCalledWith(expect.anything(), expect.any(String));
    });
    await scrolled(inbox, 'INBOX', 400);
    expect(shown(inbox, 'INBOX')).toHaveLength(400);
  });

  it.each([
    { code: 'mailbox-revoked', kind: 'loading', removals: 1 },
    { code: 'locked', kind: 'locked', removals: 0 },
  ])(
    'closes access when scrolling discovers $code',
    async ({ code, kind, removals }) => {
      expect.hasAssertions();
      const gmail = createGmail();
      mailbox(gmail, 400, 0);
      const removed = vi.fn<() => void>();
      const inbox = createGmailInbox(
        {
          ...gmail.native,
          openMailboxSegment: vi
            .fn<Gmail['native']['openMailboxSegment']>()
            .mockRejectedValue({ code }),
        },
        { removed },
      );
      await inbox.load();
      await backfilled(inbox);
      inbox.showOlder('INBOX');
      await vi.waitFor(() => {
        expect(inbox.getSnapshot().kind).toBe(kind);
      });
      expect(removed).toHaveBeenCalledTimes(removals);
    },
  );

  it('downloads All Mail in pages after the Inbox is usable', async () => {
    expect.hasAssertions();
    const { gmail, inbox, everything, allMailIds } = await downloaded();
    // The Inbox listing came first; history pages follow in the background.
    expect(historyPages(gmail)).toStrictEqual([]);
    expect(ids(shown(inbox, 'INBOX'))).toStrictEqual(everything.slice(0, 200));
    await backfilled(inbox);
    expect(ready(inbox.getSnapshot()).history).toStrictEqual({
      downloaded: 995,
      total: 1000,
      complete: true,
    });
    expect(historyPages(gmail)).toStrictEqual([
      '',
      ...Array.from({ length: 9 }, (_, page) => String((page + 1) * 100)),
    ]);
    // The document keeps checkpoints and segment names; the segments hold older messages.
    expect(savedIds(gmail)).not.toContain(allMailIds.at(-1));
  });

  it('reveals downloaded history while scrolling, without asking Gmail', async () => {
    expect.hasAssertions();
    const { gmail, inbox, everything, allMailIds } = await downloaded();
    await backfilled(inbox);
    inbox.openView(allMail);
    await vi.waitFor(() => {
      expect(shown(inbox, allMail)).toHaveLength(200);
    });
    const requests = gmail.requests.length;
    await scrolled(inbox, allMail, 995);
    await scrolled(inbox, 'INBOX', 300);
    expect(gmail.requests).toHaveLength(requests);
    expect(ids(shown(inbox, allMail))).toStrictEqual(allMailIds);
    expect(ids(shown(inbox, 'INBOX'))).toStrictEqual(everything.slice(0, 300));
    const view = ready(inbox.getSnapshot()).views?.find(
      ({ label }) => label === allMail,
    );
    expect(view?.limited).toBeUndefined();
  });

  it('resumes an interrupted backfill after relaunch without rewinding or duplicating mail', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = mailbox(gmail, 1000, 800);
    gmail.failPage('400', { code: 'unavailable' });
    const interrupted = createGmailInbox(gmail.native);
    await interrupted.load();
    await vi.waitFor(() => {
      expect(historyPages(gmail)).toContain('400');
    });
    expect(ready(interrupted.getSnapshot()).history).toMatchObject({
      downloaded: 400,
      complete: false,
    });

    const relaunched = createGmailInbox(gmail.native);
    await relaunched.load();
    await backfilled(relaunched);
    expect(historyPages(gmail)).toStrictEqual([
      '',
      '100',
      '200',
      '300',
      '400',
      '400',
      '500',
      '600',
      '700',
      '800',
      '900',
    ]);
    relaunched.openView(allMail);
    await vi.waitFor(() => {
      expect(shown(relaunched, allMail)).toHaveLength(200);
    });
    await scrolled(relaunched, allMail, 1000);
    expect(ids(shown(relaunched, allMail))).toStrictEqual(everything);
  });

  it('applies new mail, deletions and read changes to downloaded history, also after folding them in', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = mailbox(gmail, 600, 400);
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await backfilled(inbox);

    const read = at(everything, -2);
    gmail.remove(at(everything, -1));
    gmail.markRead(read);
    const arrived = gmail.deliver({ subject: 'Arrived later' });
    await inbox.load();
    inbox.openView(allMail);
    await vi.waitFor(() => {
      expect(shown(inbox, allMail)).toHaveLength(200);
    });
    await scrolled(inbox, allMail, 599);
    expect(ids(shown(inbox, allMail))).toStrictEqual([
      arrived,
      ...everything.slice(0, -1),
    ]);
    expect(shown(inbox, allMail).at(-1)).toMatchObject({
      id: read,
      unread: false,
    });

    // Enough changes to fold them into the segments.
    const older = everything.slice(200, 450);
    for (const id of older) {
      gmail.markRead(id);
    }
    await inbox.load();
    await vi.waitFor(() => {
      expect(saved(gmail)).toContain('"changes":[]');
    });

    const relaunched = createGmailInbox(gmail.native);
    await relaunched.load();
    relaunched.openView(allMail);
    await vi.waitFor(() => {
      expect(shown(relaunched, allMail)).toHaveLength(200);
    });
    await scrolled(relaunched, allMail, 599);
    expect(ids(shown(relaunched, allMail))).toStrictEqual([
      arrived,
      ...everything.slice(0, -1),
    ]);
    expect(
      shown(relaunched, allMail)
        .filter(({ id }) => older.includes(id))
        .every(({ unread }) => !unread),
    ).toBe(true);
  });

  it('reveals an older message added to a view after its segment was read', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = mailbox(gmail, 600, 0);
    const label = gmail.createLabel('History');
    for (const id of everything.slice(0, 300)) {
      gmail.setLabel(id, label, true);
    }
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await backfilled(inbox);
    inbox.openView(label);
    await vi.waitFor(() => {
      expect(shown(inbox, label)).toHaveLength(200);
    });
    await scrolled(inbox, label, 300);
    inbox.showOlder(label);
    await vi.waitFor(() => {
      expect(
        ready(inbox.getSnapshot()).views?.find((view) => view.label === label)
          ?.limited,
      ).toBeUndefined();
    });
    const restored = at(everything, -1);
    gmail.setLabel(restored, label, true);
    await inbox.load();
    await vi.waitFor(() => {
      expect(ids(shown(inbox, label))).toStrictEqual([
        ...everything.slice(0, 300),
        restored,
      ]);
    });
    inbox.forget();
  });

  it.each([
    {
      outcome: 'read',
      action: gmailAction.read,
      deleted: false,
      count: 400,
      unread: false,
    },
    {
      outcome: 'archive',
      action: gmailAction.archive,
      deleted: false,
      count: 399,
      unread: undefined,
    },
    {
      outcome: 'deleted',
      action: gmailAction.read,
      deleted: true,
      count: 399,
      unread: undefined,
    },
  ])(
    'keeps $outcome settlement on revealed mail if history refresh fails',
    async ({ action, deleted, count, unread }) => {
      expect.hasAssertions();
      const gmail = createGmail();
      mailbox(gmail, 400, 0);
      const inbox = createGmailInbox(
        withoutHistoryAfterOrganizing(gmail, deleted),
      );
      await inbox.load();
      await backfilled(inbox);
      await scrolled(inbox, 'INBOX', 400);
      const oldest = at(shown(inbox, 'INBOX'), -1);
      expect(oldest.unread).toBe(true);
      await inbox.organize(oldest, action);
      expect(ready(inbox.getSnapshot()).pending).toBe(0);
      expect(shown(inbox, 'INBOX')).toHaveLength(count);
      expect(
        shown(inbox, 'INBOX').find(({ id }) => id === oldest.id)?.unread,
      ).toBe(unread);
      inbox.forget();
    },
  );

  it.each([
    { history: 'completed empty', kept: 0 },
    { history: 'emptied after completing', kept: 250 },
  ])(
    'keeps mail arriving after a $history history scrollable offline',
    async ({ kept }) => {
      expect.hasAssertions();
      const gmail = createGmail();
      const before = mailbox(gmail, kept, 0);
      const inbox = createGmailInbox(gmail.native);
      await inbox.load();
      await backfilled(inbox);

      for (const id of before) {
        gmail.remove(id);
      }
      await inbox.load();
      await vi.waitFor(() => {
        expect(saved(gmail)).toContain('"changes":[]');
      });
      const arrived = mailbox(gmail, 300, 0);
      await inbox.load();
      await vi.waitFor(() => {
        expect(saved(gmail)).toContain('"changes":[]');
      });

      const relaunched = createGmailInbox(gmail.native);
      await relaunched.load();
      await scrolled(relaunched, 'INBOX', 300);
      expect(ids(shown(relaunched, 'INBOX'))).toStrictEqual(arrived);
    },
  );

  it("runs recent-body prefetch and history backfill in the connection's one speculative lane", async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    recentMailbox(gmail, 60);
    const prefetch = holdingPrefetch(gmail);
    const inbox = createGmailInbox(prefetch.native);
    await inbox.load();
    await prefetch.reached;
    // Gives a second lane time to reach Gmail.
    await setTimeout(100);

    expect(historyPages(gmail)).toStrictEqual([]);

    prefetch.release();
    await backfilled(inbox);

    expect(historyPages(gmail)).toStrictEqual(['']);
  });

  it('opens a message while history backfill holds the speculative lane', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const [newest] = mailbox(gmail, 300, 0);
    const history = holdingHistory(gmail);
    history.hold();
    const inbox = createGmailInbox(history.native);
    await inbox.load();
    await history.reached;
    await inbox.readMessage(at([newest], 0));

    expect(inbox.messageBody(at([newest], 0))?.kind).toBe('ready');

    history.release();
    await backfilled(inbox);
  });

  it('lets a queued synchronization run before the next history page', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    mailbox(gmail, 400, 0);
    const history = holdingHistory(gmail);
    history.hold();
    const sync = recordingSyncPages(gmail, history.native);
    const inbox = createGmailInbox(sync.native);
    await inbox.load();
    await history.reached;
    sync.pages.length = 0;
    const refresh = inbox.load();
    history.release();
    await refresh;
    await backfilled(inbox);

    expect(sync.pages[0]).toBe(1);
  });

  it('rechecks interactive priority after waiting for the speculative lane', async () => {
    expect.hasAssertions();
    vi.useFakeTimers();
    // This journey isolates scheduler admission; persistence journeys use createGmail above.
    const gmail = createSyntheticGmail();
    const older = at(mailbox(gmail, 1, 0), 0);
    recentMailbox(gmail, 1);
    const prefetch = holdingPrefetch(gmail);
    const body = holdingBody(prefetch.native, older);
    const inbox = createGmailInbox(body.native);
    try {
      const loading = inbox.load();
      await vi.runAllTimersAsync();
      await loading;
      const reading = inbox.readMessage(older);
      await body.reached;
      prefetch.release();
      await vi.runAllTimersAsync();

      expect(historyPages(gmail)).toStrictEqual([]);

      // Waiting for that body must not keep a foreground refresh's sync permit.
      const refreshing = inbox.load();
      await vi.runAllTimersAsync();
      await refreshing;

      body.release();
      await reading;
      await vi.runAllTimersAsync();
      expect(ready(inbox.getSnapshot()).history?.complete).toBe(true);
    } finally {
      body.release();
      prefetch.release();
      inbox.forget();
      vi.useRealTimers();
    }
  });

  it('keeps downloaded history visible while a pass after an expired history ID reconciles it', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = mailbox(gmail, 500, 300);
    const history = holdingHistory(gmail);
    const inbox = createGmailInbox(history.native);
    await inbox.load();
    await backfilled(inbox);
    inbox.openView(allMail);
    await vi.waitFor(() => {
      expect(shown(inbox, allMail)).toHaveLength(200);
    });
    await scrolled(inbox, allMail, 500);

    // The fake keeps its history ID until the next change, so expire before removing.
    gmail.expireHistory();
    gmail.remove(at(everything, -1));
    history.hold();
    await inbox.load();
    expect(ready(inbox.getSnapshot()).history?.complete).toBe(false);
    expect(ids(shown(inbox, allMail))).toStrictEqual(everything);

    history.release();
    await backfilled(inbox);
    await vi.waitFor(() => {
      expect(ids(shown(inbox, allMail))).toStrictEqual(everything.slice(0, -1));
    });
  });

  it('backfills tens of thousands of messages in pages', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = mailbox(gmail, 20_000, 19_500);
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await backfilled(inbox);
    expect(ready(inbox.getSnapshot()).history).toStrictEqual({
      downloaded: 20_000,
      total: 20_000,
      complete: true,
    });
    expect(historyPages(gmail)).toHaveLength(200);
    expect(savedIds(gmail)).not.toContain(everything.at(-1));

    inbox.openView(allMail);
    await vi.waitFor(() => {
      expect(shown(inbox, allMail)).toHaveLength(200);
    });
    await scrolled(inbox, allMail, 1000);
    expect(ids(shown(inbox, allMail)).slice(0, 1000)).toStrictEqual(
      everything.slice(0, 1000),
    );
  }, 120_000);
});
