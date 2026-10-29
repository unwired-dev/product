import type { ImapInboxState } from '@private-email/mail-core/imap-inbox';

import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import * as Schema from 'effect/Schema';

import { withNativeHistory } from './native-history-store.ts';

const createImap = () => withNativeHistory(createSyntheticImap());
type Imap = ReturnType<typeof createImap>;

const ready = (state: ImapInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready IMAP Inbox, received ${state.kind}`);
  }
  return state;
};

// Delivers `count` messages to the folder, oldest first, and returns their UIDs.
const fill = (imap: Imap, folder: string, count: number) =>
  Array.from({ length: count }, (_, index) =>
    imap.deliver(folder, { subject: `${folder} ${index}` }),
  );

const historyOf = (inbox: ReturnType<typeof createImapInbox>) =>
  ready(inbox.getSnapshot()).history;

const completed = async (inbox: ReturnType<typeof createImapInbox>) => {
  await vi.waitFor(
    () => {
      expect(historyOf(inbox)?.complete).toBe(true);
    },
    { timeout: 30_000 },
  );
  return historyOf(inbox);
};

const historyReads = (imap: Imap) =>
  imap.server.reads.filter((read) => read.startsWith('history '));

const decodeSegment = Schema.decodeUnknownSync(
  Schema.fromJsonString(
    Schema.Array(Schema.Struct({ folder: Schema.String, uid: Schema.Int })),
  ),
);

// The UIDs every saved segment of the folder holds.
const savedUids = (imap: Imap, folder: string) =>
  [...imap.segments.values()].flatMap((segment) =>
    decodeSegment(segment)
      .filter((message) => message.folder === folder)
      .map(({ uid }) => uid),
  );

// Runs `before` ahead of the history read numbered `at`, as the server changes mid-backfill.
const beforeHistoryRead = (imap: Imap, at: number, before: () => void) => {
  const read = imap.native.imapHistory;
  let calls = 0;
  vi.spyOn(imap.native, 'imapHistory').mockImplementation(
    async (...request) => {
      calls += 1;
      if (calls === at) {
        before();
      }
      return read(...request);
    },
  );
};

describe('imap historical metadata backfill', () => {
  it('downloads every folder in bounded reads while the Inbox keeps its newest messages', async () => {
    expect.hasAssertions();
    const imap = createImap();
    imap.addFolder('Archive', ['archive']);
    const inboxUids = fill(imap, 'INBOX', 1100);
    const archived = fill(imap, 'Archive', 600);
    const inbox = createImapInbox(imap.native);
    await inbox.load();

    await expect(completed(inbox)).resolves.toStrictEqual({
      downloaded: 1700,
      total: 1700,
      complete: true,
    });
    expect(ready(inbox.getSnapshot()).messages).toHaveLength(200);
    // The Inbox first, then each folder, newest first and at most 500 messages per read.
    expect(historyReads(imap)).toStrictEqual([
      'history INBOX next',
      `history INBOX ${inboxUids[600]}`,
      `history INBOX ${inboxUids[100]}`,
      'history Archive next',
      `history Archive ${archived[100]}`,
    ]);
    expect(new Set(savedUids(imap, 'INBOX'))).toStrictEqual(new Set(inboxUids));
    expect(new Set(savedUids(imap, 'Archive'))).toStrictEqual(
      new Set(archived),
    );
  });

  it('pauses at a failed read and resumes from its saved cursor after a relaunch', async () => {
    expect.hasAssertions();
    const imap = createImap();
    const uids = fill(imap, 'INBOX', 1100);
    beforeHistoryRead(imap, 2, () => {
      imap.server.historyFailure = 'offline';
    });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    await vi.waitFor(() => {
      expect(historyOf(inbox)).toStrictEqual({
        downloaded: 500,
        total: 1100,
        complete: false,
        paused: true,
      });
    });
    expect(ready(inbox.getSnapshot()).status).toBe('current');

    imap.server.historyFailure = undefined;
    const reads = historyReads(imap).length;
    const relaunched = createImapInbox(imap.native);
    await relaunched.load();

    await expect(completed(relaunched)).resolves.toStrictEqual({
      downloaded: 1100,
      total: 1100,
      complete: true,
    });
    // The relaunch reads on below the last saved page instead of starting over.
    expect(historyReads(imap).slice(reads)).toStrictEqual([
      `history INBOX ${uids[600]}`,
      `history INBOX ${uids[100]}`,
    ]);
    expect(new Set(savedUids(imap, 'INBOX'))).toStrictEqual(new Set(uids));
  });

  it('reconciles expunges and arrivals that happen while the backfill runs', async () => {
    expect.hasAssertions();
    const imap = createImap();
    const uids = fill(imap, 'INBOX', 1100);
    const expunged = [uids[1050], uids[0]].filter((uid) => uid !== undefined);
    let arrived = 0;
    // The first page was saved: one of its messages and an unread one go, one arrives.
    beforeHistoryRead(imap, 2, () => {
      for (const uid of expunged) {
        imap.expunge('INBOX', uid);
      }
      arrived = imap.deliver('INBOX', { subject: 'Arrived mid-backfill' });
    });
    const inbox = createImapInbox(imap.native);
    await inbox.load();

    await expect(completed(inbox)).resolves.toStrictEqual({
      downloaded: 1099,
      total: 1099,
      complete: true,
    });
    const saved = savedUids(imap, 'INBOX');
    expect(saved).toHaveLength(1099);
    expect(saved).toContain(arrived);
    expect(saved).not.toContain(expunged[0]);
    expect(saved).not.toContain(expunged[1]);
  });

  it.each([
    {
      mode: 'reload',
      resume: (_imap: Imap, inbox: ReturnType<typeof createImapInbox>) => inbox,
    },
    {
      mode: 'relaunch',
      resume: (imap: Imap) => createImapInbox(imap.native),
    },
  ])(
    'restarts only the folder whose UIDVALIDITY changed after $mode',
    async ({ resume }) => {
      expect.hasAssertions();
      const imap = createImap();
      imap.addFolder('Archive', ['archive']);
      fill(imap, 'INBOX', 300);
      fill(imap, 'Archive', 300);
      const inbox = createImapInbox(imap.native);
      await inbox.load();
      await completed(inbox);
      const segments = new Set(imap.segments.keys());
      const inboxSegments = [...imap.segments].filter(([, segment]) =>
        segment.includes('"folder":"INBOX"'),
      );

      imap.renumber('Archive');
      // An opened folder observes the new identity before the next Inbox synchronization.
      await inbox.openFolder('Archive');
      const resumed = resume(imap, inbox);
      await resumed.load();

      // The renumbered folder's old UIDs are gone; its new ones follow them.
      await vi.waitFor(() => {
        expect(new Set(savedUids(imap, 'Archive'))).toStrictEqual(
          new Set(Array.from({ length: 300 }, (_, index) => 301 + index)),
        );
      });
      await expect(completed(resumed)).resolves.toStrictEqual({
        downloaded: 600,
        total: 600,
        complete: true,
      });
      expect(
        new Map([...imap.segments].filter(([name]) => segments.has(name))),
      ).toStrictEqual(new Map(inboxSegments));
    },
  );

  it('keeps a folder history while it is listed, after its opened view leaves the bounded cache', async () => {
    expect.hasAssertions();
    const imap = createImap();
    imap.addFolder('Archive', ['archive']);
    const archived = fill(imap, 'Archive', 300);
    const others = Array.from({ length: 8 }, (_, index) => `Folder ${index}`);
    for (const name of others) {
      imap.addFolder(name);
      imap.deliver(name, { subject: `In ${name}` });
    }
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    await inbox.openFolder('Archive');
    await completed(inbox);

    for (const name of others) {
      await inbox.openFolder(name);
    }

    expect(imap.cache.document).not.toContain('"name":"Archive","cache"');
    expect(historyOf(inbox)).toStrictEqual({
      downloaded: 308,
      total: 308,
      complete: true,
    });
    expect(new Set(savedUids(imap, 'Archive'))).toStrictEqual(
      new Set(archived),
    );

    // A folder the server stops offering takes its history segments with it.
    imap.removeFolder('Archive');
    await inbox.load();
    expect(savedUids(imap, 'Archive')).toStrictEqual([]);
    expect(imap.cache.document).not.toContain('"folder":"Archive"');
  });

  it('asks for the password again when a history read is refused', async () => {
    expect.hasAssertions();
    const imap = createImap();
    fill(imap, 'INBOX', 600);
    imap.server.historyFailure = 'imap-refused';
    const inbox = createImapInbox(imap.native);
    await inbox.load();

    await vi.waitFor(() => {
      expect(ready(inbox.getSnapshot()).status).toBe('authentication');
    });
  });
});
