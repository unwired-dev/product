import type { GmailInboxState } from '../src/gmail-inbox.ts';

import { allMail } from '../src/gmail-actions.ts';
import { createGmailInbox } from '../src/gmail-inbox.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';

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

const at = (messages: readonly string[], index: number) => {
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
        await listing.promise;
      }
      return gmail.native.gmailRequest(path, query, request);
    },
  };
  return {
    native,
    hold: () => {
      holding = true;
    },
    release: () => {
      holding = false;
      listing.resolve(undefined);
    },
  };
};

// A mailbox with spam whose history is downloaded, and the All Mail IDs newest first.
const downloaded = async () => {
  const gmail = createSyntheticGmail();
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
    const gmail = createSyntheticGmail();
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
    const gmail = createSyntheticGmail();
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

  it('keeps downloaded history visible while a pass after an expired history ID reconciles it', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
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
    const gmail = createSyntheticGmail();
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
