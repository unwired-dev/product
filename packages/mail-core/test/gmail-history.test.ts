import { setImmediate } from 'node:timers/promises';

import type { GmailInboxState } from '@private-email/mail-core/gmail-inbox';

import {
  allMail,
  gmailAction,
  gmailArchive,
} from '@private-email/mail-core/gmail-actions';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';

import { withNativeHistory } from './native-history-store.ts';

const createGmail = () => withNativeHistory(createSyntheticGmail());

type Inbox = ReturnType<typeof createGmailInbox>;
type Gmail = ReturnType<typeof createSyntheticGmail>;

// Stop background work before the signed storage process's earlier-registered teardown closes it.
const createInbox = (...args: Parameters<typeof createGmailInbox>) => {
  const inbox = createGmailInbox(...args);
  onTestFinished(() => inbox.forget());
  return inbox;
};

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

// The Inbox is always open; any other view opens as the app would show it.
const opened = async (inbox: Inbox, label: string) => {
  if (label !== 'INBOX') {
    await inbox.openView(label);
  }
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
const holdingHistory = (gmail: Gmail, pageToken?: string) => {
  const listing = Promise.withResolvers<undefined>();
  const reached = Promise.withResolvers<undefined>();
  let holding = false;
  const native: Gmail['native'] = {
    ...gmail.native,
    gmailRequest: async (path, query, request) => {
      if (
        holding &&
        (pageToken === undefined ||
          query.some(
            ([name, value]) => name === 'pageToken' && value === pageToken,
          )) &&
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

// Refuses reveal reads only after the fold's metadata and segments are durable.
const refusingFoldReveals = (gmail: Gmail, code: string) => {
  let armed = false;
  let refused = false;
  const read = vi.fn<Gmail['native']['openMailboxSegment']>(
    gmail.native.openMailboxSegment,
  );
  return {
    arm: () => {
      armed = true;
    },
    refused: () => refused,
    resume: () => {
      armed = false;
      read.mockImplementation(gmail.native.openMailboxSegment);
    },
    native: {
      ...gmail.native,
      commitMailbox: async (...args) => {
        const result = await gmail.native.commitMailbox(...args);
        if (armed && args[3] !== undefined) {
          refused = true;
          read.mockRejectedValue({ code });
        }
        return result;
      },
      openMailboxSegment: read,
    } satisfies Gmail['native'],
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
const holdingPrefetch = (gmail: Gmail, status = 200) => {
  const metadata = Promise.withResolvers<undefined>();
  const reached = Promise.withResolvers<undefined>();
  let responseStatus = status;
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
        if (responseStatus !== 200) {
          return { status: responseStatus, body: '{}' };
        }
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
    resume: () => {
      responseStatus = 200;
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

// Holds the first prune that removes this body, before its new metadata is published.
const holdingBodyPrune = (native: Gmail['native'], id: string) => {
  const reached = Promise.withResolvers<undefined>();
  const release = Promise.withResolvers<undefined>();
  let holding = false;
  return {
    reached: reached.promise,
    hold: () => {
      holding = true;
    },
    release: () => release.resolve(undefined),
    native: {
      ...native,
      retainMessageBodies: async (...args) => {
        const reply = await native.retainMessageBodies(...args);
        if (holding && !args[1].includes(id)) {
          holding = false;
          reached.resolve(undefined);
          await release.promise;
        }
        return reply;
      },
    } satisfies Gmail['native'],
  };
};

// A provider action settles, but the following history read cannot refresh older segments.
const withoutHistoryAfterOrganizing = (
  gmail: Gmail,
  deleted: boolean,
  refuseAll = false,
) => {
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
      (refuseAll || path === 'history') && refuseHistory
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
  const inbox = createInbox(gmail.native);
  await inbox.load();
  return {
    gmail,
    inbox,
    everything,
    allMailIds: everything.filter((id) => !spam.includes(id)),
  };
};

describe('gmail history backfill', () => {
  it.each(['2026-10-27T09:42:00.000Z', '2026-10-27T08:41:00.000Z'])(
    'preserves the latest successful synchronization at %s when an older history page rebases',
    async (synchronizedAt) => {
      expect.hasAssertions();
      vi.useFakeTimers({ toFake: ['Date'] });
      onTestFinished(() => {
        vi.useRealTimers();
      });
      vi.setSystemTime('2026-10-27T09:41:00Z');
      const gmail = createGmail();
      mailbox(gmail, 1, 0);
      const history = holdingHistory(gmail);
      history.hold();
      onTestFinished(history.release);
      const inbox = createInbox(history.native);
      await inbox.load();
      await history.reached;

      vi.setSystemTime(synchronizedAt);
      const newer = createInbox({
        ...gmail.native,
        gmailRequest: (path, query, request) => {
          /* oxlint-disable vitest/no-conditional-in-test -- Only the competing store's background history is unavailable. */
          if (
            path === 'messages' &&
            query.some(
              ([name, value]) => name === 'maxResults' && value === '100',
            )
          ) {
            return Promise.resolve({ status: 503, body: '{}' });
          }
          /* oxlint-enable vitest/no-conditional-in-test */
          return gmail.native.gmailRequest(path, query, request);
        },
      });
      await newer.load();
      expect(ready(newer.getSnapshot()).synchronizedAt).toBe(synchronizedAt);
      newer.forget();

      history.release();
      await backfilled(inbox);
      expect(ready(inbox.getSnapshot()).synchronizedAt).toBe(synchronizedAt);
      const cache = await gmail.native.openMailbox();
      const relaunched = createInbox({
        ...gmail.native,
        openMailbox: () => Promise.resolve({ ...cache, availability: 'retry' }),
      });
      await relaunched.load();
      expect(ready(relaunched.getSnapshot()).synchronizedAt).toBe(
        synchronizedAt,
      );
    },
  );

  it('reveals equal-timestamp pages without duplicating folded changes', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const older = Array.from({ length: 1850 }, () =>
      gmail.deliver({ at: 1_700_000_000_000 }),
    );
    const newer = Array.from({ length: 450 }, () =>
      gmail.deliver({ at: 1_700_000_001_000 }),
    );
    const everything = [
      ...newer.toSorted().toReversed(),
      ...older.toSorted().toReversed(),
    ];
    const inbox = createInbox(gmail.native);
    await inbox.load();
    await backfilled(inbox);
    await scrolled(inbox, 'INBOX', everything.length);
    expect(ids(shown(inbox, 'INBOX'))).toStrictEqual(everything);
    // These originals lie beyond the fold's first 20 segments, so deduplication must resume too.
    for (const id of older.slice(-250)) {
      gmail.markRead(id);
    }
    await inbox.load();
    await vi.waitFor(() => {
      expect(saved(gmail)).toContain('"changes":[]');
    });
    expect(ready(inbox.getSnapshot()).history?.downloaded).toBe(
      everything.length,
    );
    await scrolled(inbox, 'INBOX', everything.length);
    expect(ids(shown(inbox, 'INBOX'))).toStrictEqual(everything);
    // 2,300 messages are downloaded, folded and scrolled twice; shared CI runners need longer.
  }, 30_000);

  it('recovers from a failed history read when scrolling again', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    mailbox(gmail, 400, 0);
    const read = vi
      .fn<Gmail['native']['openMailboxSegment']>()
      .mockImplementation(gmail.native.openMailboxSegment)
      .mockRejectedValueOnce({ code: 'unavailable' });
    const inbox = createInbox({
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
      const inbox = createInbox(
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

  it('reveals one batch of downloaded history per scroll', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    mailbox(gmail, 1000, 0);
    const read = vi
      .fn<Gmail['native']['openMailboxSegment']>()
      .mockImplementation(gmail.native.openMailboxSegment);
    const inbox = createInbox({
      ...gmail.native,
      openMailboxSegment: read,
    });
    await inbox.load();
    await backfilled(inbox);
    await scrolled(inbox, 'INBOX', 201);
    // One batch of 50 needs the first three pages of 100, not the whole mailbox.
    expect(shown(inbox, 'INBOX')).toHaveLength(300);
    expect(read.mock.calls.length).toBeLessThanOrEqual(3);
    const reads = read.mock.calls.length;
    await inbox.load();
    expect(read).toHaveBeenCalledTimes(reads);
  });

  it('fulfils a pending scroll as backfill commits new pages', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = mailbox(gmail, 500, 0);
    const history = holdingHistory(gmail, '300');
    history.hold();
    const inbox = createInbox(history.native);
    try {
      await inbox.load();
      await history.reached;
      await scrolled(inbox, 'INBOX', 300);
      inbox.showOlder('INBOX');
      history.release();
      await backfilled(inbox);

      await vi.waitFor(() => {
        expect(ids(shown(inbox, 'INBOX'))).toStrictEqual(
          everything.slice(0, 400),
        );
      });
    } finally {
      history.release();
    }
  });

  it.each(['SPAM', 'TRASH'])(
    'keeps %s scrolling outside All Mail history reads',
    async (label) => {
      expect.hasAssertions();
      vi.useFakeTimers();
      const gmail = createSyntheticGmail();
      for (const id of mailbox(gmail, 650, 0).slice(0, 250)) {
        gmail.setLabel(id, label, true);
      }
      const read = vi
        .fn<Gmail['native']['openMailboxSegment']>()
        .mockImplementation(gmail.native.openMailboxSegment);
      const inbox = createInbox({
        ...gmail.native,
        openMailboxSegment: read,
      });
      try {
        const loading = inbox.load();
        await vi.runAllTimersAsync();
        await loading;
        expect(ready(inbox.getSnapshot()).history?.complete).toBe(true);
        const opening = inbox.openView(label);
        await vi.runAllTimersAsync();
        await opening;
        const before = shown(inbox, label);
        expect(before).toHaveLength(200);

        inbox.showOlder(label);
        await vi.runAllTimersAsync();

        expect(read).not.toHaveBeenCalled();
        expect(shown(inbox, label)).toStrictEqual(before);
        expect(
          ready(inbox.getSnapshot()).views?.find((view) => view.label === label)
            ?.limited,
        ).toBe(true);
      } finally {
        inbox.forget();
        vi.useRealTimers();
      }
    },
  );

  it('resumes an interrupted backfill after relaunch without rewinding or duplicating mail', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = mailbox(gmail, 1000, 800);
    gmail.failPage('400', { code: 'unavailable' });
    const interrupted = createInbox(gmail.native);
    await interrupted.load();
    await vi.waitFor(() => {
      expect(historyPages(gmail)).toContain('400');
    });
    expect(ready(interrupted.getSnapshot()).history).toMatchObject({
      downloaded: 400,
      complete: false,
    });

    const relaunched = createInbox(gmail.native);
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
    const inbox = createInbox(gmail.native);
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

    const relaunched = createInbox(gmail.native);
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
    const inbox = createInbox(gmail.native);
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

  it('reveals archived history in the Archive view the unified Archive lists', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = mailbox(gmail, 600, 300);
    const inbox = createInbox(gmail.native);
    await inbox.load();
    await backfilled(inbox);
    inbox.openView(gmailArchive);
    await vi.waitFor(() => {
      expect(shown(inbox, gmailArchive)).toHaveLength(200);
    });
    await scrolled(inbox, gmailArchive, 300);
    expect(ids(shown(inbox, gmailArchive))).toStrictEqual(
      everything.slice(300),
    );
    inbox.forget();
  });

  it('reveals mail restored from Trash only once the newer history before it is read', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = mailbox(gmail, 660, 0);
    const restored = everything.slice(-60);
    for (const id of restored) {
      gmail.setLabel(id, 'TRASH', true);
    }
    const inbox = createInbox(gmail.native);
    await inbox.load();
    await backfilled(inbox);
    for (const id of restored) {
      gmail.setLabel(id, 'TRASH', false);
    }
    await inbox.load();
    await inbox.openView(allMail);

    await scrolled(inbox, allMail, 300);
    const visible = ids(shown(inbox, allMail));
    expect(visible).toStrictEqual(everything.slice(0, visible.length));
    await scrolled(inbox, allMail, everything.length);
    expect(ids(shown(inbox, allMail))).toStrictEqual(everything);
  });

  it.each([
    { mode: 'verified', access: {}, sync: 'current' },
    { mode: 'cache-only', access: { availability: 'retry' }, sync: 'retry' },
  ])(
    'drops revealed rows deleted while another Inbox folded completed history ($mode)',
    async ({ access, mode, sync }) => {
      expect.hasAssertions();
      const gmail = createGmail();
      const everything = mailbox(gmail, 500, 0);
      let cacheAccess: Readonly<{ availability?: string }> = {};
      const inbox = createInbox({
        ...gmail.native,
        openMailbox: async () => ({
          ...(await gmail.native.openMailbox()),
          ...cacheAccess,
        }),
      });
      await inbox.load();
      await backfilled(inbox);
      await scrolled(inbox, 'INBOX', 500);

      // Enough deletions to fold them into the segments.
      const removed = everything.slice(200, 400);
      for (const id of removed) {
        gmail.remove(id);
      }
      const other = createInbox(gmail.native);
      await other.load();
      await vi.waitFor(() => {
        expect(saved(gmail)).toContain('"changes":[]');
      });
      cacheAccess = access;
      const requests = gmail.requests.length;
      await inbox.load();
      expect(gmail.requests.length === requests).toBe(mode === 'cache-only');
      expect(ready(inbox.getSnapshot()).sync).toBe(sync);

      const gone = new Set(removed);
      await vi.waitFor(() => {
        expect(ids(shown(inbox, 'INBOX'))).toStrictEqual(
          everything.filter((id) => !gone.has(id)),
        );
      });
    },
  );

  it.each([
    {
      code: 'unavailable',
      state: { kind: 'ready', sync: 'current' },
      removals: 0,
    },
    { code: 'locked', state: { kind: 'locked' }, removals: 0 },
    { code: 'mailbox-revoked', state: { kind: 'loading' }, removals: 1 },
  ])(
    'recovers from $code while revealing an already committed fold',
    async ({ code, state, removals }) => {
      expect.hasAssertions();
      const gmail = createGmail();
      const everything = mailbox(gmail, 500, 0);
      const refusal = refusingFoldReveals(gmail, code);
      const removed = vi.fn<() => void>();
      const inbox = createInbox(refusal.native, { removed });
      await inbox.load();
      await backfilled(inbox);
      await scrolled(inbox, 'INBOX', 500);
      for (const id of everything.slice(200, 400)) {
        gmail.markRead(id);
      }
      refusal.arm();
      await inbox.load();

      await vi.waitFor(() => {
        expect(refusal.refused()).toBe(true);
        expect(inbox.getSnapshot()).toMatchObject(state);
        expect(removed).toHaveBeenCalledTimes(removals);
      });
      expect(saved(gmail)).toContain('"changes":[]');
      refusal.resume();
      await inbox.load();
      expect(ready(inbox.getSnapshot()).sync).toBe('current');
      await scrolled(inbox, 'INBOX', 500);
      expect(ids(shown(inbox, 'INBOX'))).toStrictEqual(everything);
    },
  );

  it("ignores a former owner's reveal revocation while a reload waits", async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = mailbox(gmail, 500, 0);
    const reached = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const read = vi.fn<Gmail['native']['openMailboxSegment']>(
      gmail.native.openMailboxSegment,
    );
    const removed = vi.fn<() => void>();
    const inbox = createInbox(
      {
        ...gmail.native,
        openMailboxSegment: read,
      },
      { removed },
    );
    await inbox.load();
    await backfilled(inbox);
    await scrolled(inbox, 'INBOX', 500);
    for (const id of everything.slice(200, 400)) {
      gmail.markRead(id);
    }
    const other = createInbox(gmail.native);
    await other.load();
    await vi.waitFor(() => {
      expect(saved(gmail)).toContain('"changes":[]');
    });

    read.mockImplementationOnce(async () => {
      reached.resolve(undefined);
      await release.promise;
      throw Object.assign(new Error('Controlled former-owner refusal'), {
        code: 'mailbox-revoked',
      });
    });
    const refreshing = inbox.load();
    try {
      await reached.promise;
      inbox.forget();
      const reopening = inbox.load();
      release.resolve(undefined);
      await refreshing;
      await reopening;

      expect(removed).not.toHaveBeenCalled();
      expect(ready(inbox.getSnapshot()).sync).toBe('current');
    } finally {
      release.resolve(undefined);
    }
  });

  it('keeps revealed history rows while a fold renames their segments', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = mailbox(gmail, 1000, 0);
    const inbox = createInbox(gmail.native);
    await inbox.load();
    await backfilled(inbox);
    await inbox.openView(allMail);
    await scrolled(inbox, allMail, 600);
    const counts: number[] = [];
    const unsubscribe = inbox.subscribe(() => {
      counts.push(shown(inbox, allMail).length);
    });
    onTestFinished(unsubscribe);

    for (const id of everything.slice(250, 500)) {
      gmail.markRead(id);
    }
    await inbox.load();
    await vi.waitFor(() => {
      expect(saved(gmail)).toContain('"changes":[]');
    });
    await vi.waitFor(() => {
      expect(ids(shown(inbox, allMail)).slice(0, 600)).toStrictEqual(
        everything.slice(0, 600),
      );
    });
    expect(Math.min(...counts)).toBeGreaterThanOrEqual(600);
  });

  it('keeps revealed rows and their reader when equal receipt dates span renamed segments', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = Array.from({ length: 1000 }, () =>
      gmail.deliver({ at: Date.UTC(2026, 8, 1) }),
    );
    const inbox = createInbox(gmail.native);
    await inbox.load();
    await backfilled(inbox);
    await inbox.openView(allMail);
    const cached = new Set(ids(shown(inbox, allMail)));
    await scrolled(inbox, allMail, 600);
    const before = ids(shown(inbox, allMail));
    const openedId = at(
      before.filter((id) => !cached.has(id)),
      0,
    );
    await inbox.readMessage(openedId);
    expect(inbox.messageBody(openedId)?.kind).toBe('ready');
    const counts: number[] = [];
    const unsubscribe = inbox.subscribe(() => {
      counts.push(shown(inbox, allMail).length);
    });
    onTestFinished(unsubscribe);

    for (const id of everything.slice(250, 500)) {
      gmail.markRead(id);
    }
    await inbox.load();
    await vi.waitFor(() => {
      expect(saved(gmail)).toContain('"changes":[]');
    });
    expect(inbox.messageBody(openedId)?.kind).toBe('ready');
    expect(Math.min(...counts)).toBeGreaterThanOrEqual(before.length);
    await scrolled(inbox, allMail, everything.length);
    expect(new Set(ids(shown(inbox, allMail)))).toStrictEqual(
      new Set(everything),
    );
  });

  it('keeps mail restored from Trash in date order among downloaded history', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const everything = mailbox(gmail, 850, 0);
    const inbox = createInbox(gmail.native);
    await inbox.load();
    await backfilled(inbox);
    const trashed = [...everything.slice(300, 500), ...everything.slice(-50)];
    for (const id of trashed) {
      gmail.setLabel(id, 'TRASH', true);
    }
    await inbox.load();
    await vi.waitFor(() => {
      expect(saved(gmail)).toContain('"changes":[]');
    });
    for (const id of trashed) {
      gmail.setLabel(id, 'TRASH', false);
    }
    await inbox.load();
    await vi.waitFor(() => {
      expect(saved(gmail)).toContain('"changes":[]');
    });

    const relaunched = createInbox(gmail.native);
    await relaunched.load();
    relaunched.openView(allMail);
    await scrolled(relaunched, allMail, 400);
    expect(ids(shown(relaunched, allMail)).slice(0, 400)).toStrictEqual(
      everything.slice(0, 400),
    );
    await scrolled(relaunched, allMail, everything.length);
    expect(ids(shown(relaunched, allMail))).toStrictEqual(everything);
    expect(ready(relaunched.getSnapshot()).history?.downloaded).toBe(
      everything.length,
    );
  });

  it.each(['INBOX', allMail])(
    'scrolls past deleted history pages to reveal older %s mail',
    async (label) => {
      expect.hasAssertions();
      const gmail = createGmail();
      const everything = mailbox(gmail, 1000, 0);
      const inbox = createInbox(gmail.native);
      await inbox.load();
      await backfilled(inbox);
      // Stay below the fold threshold, leaving deleted rows in the first segments.
      for (const id of everything.slice(0, 150)) {
        gmail.remove(id);
      }
      await inbox.load();
      await opened(inbox, label);
      expect(shown(inbox, label)).toHaveLength(200);
      const requests = gmail.requests.length;

      inbox.showOlder(label);

      await vi.waitFor(() => {
        expect(shown(inbox, label).length).toBeGreaterThan(200);
      });
      expect(ids(shown(inbox, label))).toStrictEqual(
        everything.slice(150, 150 + shown(inbox, label).length),
      );
      expect(gmail.requests).toHaveLength(requests);
    },
  );

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
      const inbox = createInbox(withoutHistoryAfterOrganizing(gmail, deleted));
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

  it.each(['INBOX', allMail])(
    'keeps older %s mail available when a confirmed removal cannot refill its recent cache',
    async (label) => {
      expect.hasAssertions();
      const gmail = createGmail();
      const everything = mailbox(gmail, 400, 0);
      const native = withoutHistoryAfterOrganizing(gmail, false, true);
      const inbox = createInbox(native);
      await inbox.load();
      await backfilled(inbox);
      inbox.openView(allMail);
      await vi.waitFor(() => {
        expect(shown(inbox, allMail)).toHaveLength(200);
      });
      await scrolled(inbox, label, 400);
      await inbox.organize(at(shown(inbox, label), 0), gmailAction.trash);
      expect(ids(shown(inbox, label))).toStrictEqual(everything.slice(1));
      inbox.forget();

      const relaunched = createInbox(native);
      await relaunched.load();
      expect(
        ready(relaunched.getSnapshot()).views?.find(
          (view) => view.label === allMail,
        )?.limited,
      ).toBe(true);
      await scrolled(relaunched, label, 399);
      expect(ids(shown(relaunched, label))).toStrictEqual(everything.slice(1));
      relaunched.forget();
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
      const inbox = createInbox(gmail.native);
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

      const relaunched = createInbox(gmail.native);
      await relaunched.load();
      await scrolled(relaunched, 'INBOX', 300);
      expect(ids(shown(relaunched, 'INBOX'))).toStrictEqual(arrived);
    },
  );

  it("runs recent-body prefetch and history backfill in the connection's one speculative lane", async () => {
    expect.hasAssertions();
    vi.useFakeTimers();
    const gmail = createSyntheticGmail();
    recentMailbox(gmail, 60);
    const prefetch = holdingPrefetch(gmail);
    const inbox = createInbox(prefetch.native);
    try {
      const loading = inbox.load();
      await vi.runAllTimersAsync();
      await loading;
      await prefetch.reached;
      expect(historyPages(gmail)).toStrictEqual([]);

      prefetch.release();
      await vi.runAllTimersAsync();
      expect(ready(inbox.getSnapshot()).history?.complete).toBe(true);
      expect(historyPages(gmail)).toStrictEqual(['']);
    } finally {
      prefetch.release();
      inbox.forget();
      vi.useRealTimers();
    }
  });

  it.each([401, 503])(
    'pauses queued history after prefetch receives HTTP %s until the next synchronization',
    async (status) => {
      expect.hasAssertions();
      vi.useFakeTimers();
      const gmail = createSyntheticGmail();
      recentMailbox(gmail, 60);
      const prefetch = holdingPrefetch(gmail, status);
      const inbox = createInbox(prefetch.native);
      try {
        const loading = inbox.load();
        await vi.runAllTimersAsync();
        await loading;
        prefetch.release();
        await vi.runAllTimersAsync();
        expect(historyPages(gmail)).toStrictEqual([]);

        prefetch.resume();
        const refreshing = inbox.load();
        await vi.runAllTimersAsync();
        await refreshing;
        expect(ready(inbox.getSnapshot()).history?.complete).toBe(true);
      } finally {
        prefetch.release();
        inbox.forget();
        vi.useRealTimers();
      }
    },
  );

  it('keeps revealed history outside the bounded recent-body prefetch selection', async () => {
    expect.hasAssertions();
    vi.useFakeTimers();
    const gmail = createSyntheticGmail();
    const everything = recentMailbox(gmail, 300);
    const inbox = createInbox(gmail.native);
    try {
      const loading = inbox.load();
      await vi.runAllTimersAsync();
      await loading;
      inbox.showOlder('INBOX');
      await vi.runAllTimersAsync();
      expect(shown(inbox, 'INBOX')).toHaveLength(300);

      const refreshing = inbox.load();
      await vi.runAllTimersAsync();
      await refreshing;
      expect([...gmail.cachedBodies().keys()]).toStrictEqual(
        everything.slice(0, 200),
      );
    } finally {
      inbox.forget();
      vi.useRealTimers();
    }
  });

  it('keeps a revealed history body only when a cached view also keeps its message', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const oldest = at(mailbox(gmail, 300, 0), 299);
    const label = gmail.createLabel('Saved history');
    gmail.setLabel(oldest, label, true);
    const inbox = createInbox(gmail.native);
    await inbox.load();
    await backfilled(inbox);
    await scrolled(inbox, 'INBOX', 300);
    await inbox.readMessage(oldest);

    expect(inbox.messageBody(oldest)?.kind).toBe('ready');
    expect(gmail.cachedBodies().has(oldest)).toBe(false);
    await expect(inbox.savedBodies([oldest])).resolves.toStrictEqual(new Set());

    await inbox.openView(label);
    await inbox.readMessage(oldest, { refresh: true });
    await inbox.load();

    await expect(inbox.savedBodies([oldest])).resolves.toStrictEqual(
      new Set([oldest]),
    );
  });

  it('shows a downloaded body when a concurrent commit moves its message into revealed history', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const id = at(mailbox(gmail, 300, 0), 199);
    const pruning = holdingBodyPrune(gmail.native, id);
    const inbox = createInbox(pruning.native);
    await inbox.load();
    await backfilled(inbox);
    await scrolled(inbox, 'INBOX', 300);
    gmail.deliver({ subject: 'New arrival' });
    pruning.hold();
    const refreshing = inbox.load();
    try {
      await pruning.reached;
      const reading = inbox.readMessage(id);
      // Let the download reach body admission while metadata publication is held.
      await setImmediate();
      pruning.release();
      await refreshing;
      await reading;

      expect(ids(shown(inbox, 'INBOX'))).toContain(id);
      expect(inbox.messageBody(id)?.kind).toBe('ready');
      await expect(inbox.savedBodies([id])).resolves.toStrictEqual(new Set());
    } finally {
      pruning.release();
    }
  });

  it('opens a message while history backfill holds the speculative lane', async () => {
    expect.hasAssertions();
    const gmail = createGmail();
    const [newest] = mailbox(gmail, 300, 0);
    const history = holdingHistory(gmail);
    history.hold();
    const inbox = createInbox(history.native);
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
    const inbox = createInbox(sync.native);
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
    const inbox = createInbox(body.native);
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
    const inbox = createInbox(history.native);
    await inbox.load();
    await backfilled(inbox);
    inbox.openView(allMail);
    await vi.waitFor(() => {
      expect(shown(inbox, allMail)).toHaveLength(200);
    });
    await scrolled(inbox, allMail, 500);

    // A pre-expiry overlay must stay visible during reconciliation, then lose mail the new pass
    // no longer lists. Otherwise that old overlay can resurrect a provider-deleted message.
    gmail.markRead(at(everything, -1));
    gmail.markRead(at(everything, -3));
    await inbox.load();
    // The fake keeps its history ID until the next change, so expire before removing.
    gmail.expireHistory();
    gmail.remove(at(everything, -1));
    history.hold();
    await inbox.load();
    expect(ready(inbox.getSnapshot()).history?.complete).toBe(false);
    expect(ids(shown(inbox, allMail))).toStrictEqual(everything);
    expect(shown(inbox, allMail).at(-3)?.unread).toBe(false);

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
    const inbox = createInbox(gmail.native);
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
