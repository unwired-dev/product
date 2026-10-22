import type { ImapInboxState } from '../src/imap-inbox.ts';

import { createImapInbox } from '../src/imap-inbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';

const now = Date.UTC(2026, 9, 20, 12);
const day = 24 * 60 * 60 * 1000;

const ready = (state: ImapInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready IMAP Inbox, received ${state.kind}`);
  }
  return state;
};
const named = (state: ImapInboxState, subject: string) => {
  const message = ready(state).messages.find(
    (candidate) => candidate.subject === subject,
  );
  if (message === undefined) {
    throw new Error(`Expected an Inbox message named ${subject}`);
  }
  return message;
};

const rawWith = (subject: string, headers: string, body: string) =>
  [
    'From: Synthetic Sender <sender@example.invalid>',
    `Subject: ${subject}`,
    'MIME-Version: 1.0',
    headers,
    '',
    body,
  ].join('\r\n');

const withAttachment = rawWith(
  'Invoice attached',
  'Content-Type: multipart/mixed;\r\n boundary="part"',
  [
    '--part',
    'Content-Type: text/plain; charset=utf-8',
    '',
    'The invoice is attached.',
    '--part',
    'Content-Type: application/pdf; name="invoice.pdf"',
    'Content-Disposition: attachment; filename="invoice.pdf"',
    'Content-Transfer-Encoding: base64',
    '',
    'JVBERi0xLjQK',
    '--part--',
  ].join('\r\n'),
);

const rejection = (code: string) =>
  Object.assign(new Error(`Synthetic ${code}`), { code });

// A controlled IMAP Inbox at a fixed instant, with mail inside and outside the recent window.
const recentInbox = () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(now);
  onTestFinished(() => {
    vi.useRealTimers();
  });
  const imap = createSyntheticImap();
  const uids = {
    plain: imap.deliver('INBOX', {
      subject: 'Plain',
      body: 'Plain body',
      received: now - day,
    }),
    html: imap.deliver('INBOX', {
      subject: 'Styled',
      raw: rawWith(
        'Styled',
        'Content-Type: text/html; charset=utf-8',
        '<p>Styled body</p>',
      ),
      received: now - 2 * day,
    }),
    attached: imap.deliver('INBOX', {
      subject: 'Invoice attached',
      raw: withAttachment,
      received: now - 3 * day,
    }),
    old: imap.deliver('INBOX', {
      subject: 'Old',
      body: 'Old body',
      received: now - 31 * day,
    }),
    future: imap.deliver('INBOX', {
      subject: 'Future',
      body: 'Future body',
      received: now + day,
    }),
  };
  const ids = {
    plain: `7.${uids.plain}.INBOX`,
    html: `7.${uids.html}.INBOX`,
    attached: `7.${uids.attached}.INBOX`,
    old: `7.${uids.old}.INBOX`,
    future: `7.${uids.future}.INBOX`,
  };
  return { imap, uids, ids };
};

// Loads the Inbox and waits for its first prefetch pass to save both bodies and the marker.
const prefetched = async () => {
  const setup = recentInbox();
  const inbox = createImapInbox(setup.imap.native);
  await inbox.load();
  await vi.waitFor(() => {
    expect([...setup.imap.tiers]).toStrictEqual([
      [setup.ids.plain, 'prefetched'],
      [setup.ids.html, 'prefetched'],
      [setup.ids.attached, 'excluded'],
    ]);
  });
  return { ...setup, inbox };
};

describe('imap recent-body prefetch', () => {
  it('saves recent single-part bodies after synchronization without reading the source of a message with an attachment', async () => {
    expect.hasAssertions();
    const { imap, inbox, uids, ids } = await prefetched();
    // One body-free read chooses the sources; mail outside the 30 days is not read.
    expect(imap.server.reads).toStrictEqual([
      'folders',
      'synchronize INBOX',
      `headers INBOX ${uids.plain},${uids.html},${uids.attached}`,
      `message INBOX ${uids.plain}`,
      `message INBOX ${uids.html}`,
    ]);
    await expect(inbox.savedBodies(Object.values(ids))).resolves.toStrictEqual(
      new Set([ids.plain, ids.html]),
    );
  });

  it('opens prefetched bodies offline and reads nothing again at the next synchronization', async () => {
    expect.hasAssertions();
    const { imap, inbox, ids } = await prefetched();
    imap.server.failure = 'offline';
    const releases = [ids.plain, ids.html].map((id) => inbox.retainMessage(id));
    await Promise.all([ids.plain, ids.html].map(inbox.readMessage));
    expect(
      [ids.plain, ids.html].map((id) => inbox.messageBody(id)?.kind),
    ).toStrictEqual(['ready', 'ready']);
    for (const release of releases) {
      release();
    }

    // Saved bodies and exclusion markers are not read again; the excluded message still
    // opens on demand and keeps the prefetched tier.
    imap.server.failure = undefined;
    imap.server.reads.length = 0;
    await inbox.load();
    expect(imap.server.reads).toStrictEqual(['folders', 'synchronize INBOX']);
    const release = inbox.retainMessage(ids.attached);
    await inbox.readMessage(ids.attached);
    expect([
      inbox.messageBody(ids.attached)?.kind,
      imap.tiers.get(ids.attached),
    ]).toStrictEqual(['ready', 'prefetched']);
    release();
  });

  it('pauses while the server cannot be reached or refuses the password, and resumes at the next synchronization', async () => {
    expect.hasAssertions();
    const { imap, ids } = recentInbox();
    const headers = vi
      .spyOn(imap.native, 'imapHeaders')
      .mockRejectedValueOnce(rejection('offline'));
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    // An unreachable server pauses prefetch; the Inbox stays current and nothing is saved.
    await vi.waitFor(() => {
      expect([
        headers.mock.settledResults.map(({ type }) => type),
        imap.bodies.size,
        ready(inbox.getSnapshot()).status,
      ]).toStrictEqual([['rejected'], 0, 'current']);
    });

    const message = vi
      .spyOn(imap.native, 'imapMessage')
      .mockRejectedValueOnce(rejection('imap-refused'));
    await inbox.load();
    await vi.waitFor(() => {
      expect(ready(inbox.getSnapshot()).status).toBe('authentication');
    });
    // The refusal stops the lane before any other message is read.
    expect([message.mock.calls.length, imap.bodies.size]).toStrictEqual([1, 0]);

    await inbox.load();
    await vi.waitFor(() => {
      expect([
        imap.bodies.has(ids.plain),
        imap.bodies.has(ids.html),
        ready(inbox.getSnapshot()).status,
      ]).toStrictEqual([true, true, 'current']);
    });
  });

  it('shares an in-flight prefetch with an explicit open of the same message', async () => {
    expect.hasAssertions();
    const { imap, uids, ids } = recentInbox();
    const requested = Promise.withResolvers<undefined>();
    const answer = Promise.withResolvers<unknown>();
    const read = imap.native.imapMessage;
    const message = vi
      .spyOn(imap.native, 'imapMessage')
      .mockImplementationOnce(async (...args) => {
        requested.resolve(undefined);
        await answer.promise;
        return read(...args);
      });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    await requested.promise;

    const release = inbox.retainMessage(ids.plain);
    const opened = inbox.readMessage(ids.plain);
    answer.resolve(undefined);
    await opened;
    expect(inbox.messageBody(ids.plain)).toMatchObject({ kind: 'ready' });
    expect(
      message.mock.calls.filter(([, request]) => request.uid === uids.plain),
    ).toHaveLength(1);
    release();
  });

  it('keeps no body a prefetch read before the folder got a new UIDVALIDITY', async () => {
    expect.hasAssertions();
    const { imap } = recentInbox();
    const requested = Promise.withResolvers<undefined>();
    const held = Promise.withResolvers<undefined>();
    const read = imap.native.imapMessage;
    vi.spyOn(imap.native, 'imapMessage').mockImplementationOnce(
      async (...args) => {
        requested.resolve(undefined);
        // The source as read before the folder changed, answered only after it changed.
        const source = await read(...args);
        await held.promise;
        return source;
      },
    );
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    await requested.promise;
    imap.renumber('INBOX');
    await inbox.load();
    held.resolve(undefined);

    const plain = named(inbox.getSnapshot(), 'Plain');
    expect(plain.uidValidity).toBe(8);
    await vi.waitFor(() => {
      expect(imap.bodies.has(plain.id)).toBe(true);
    });
    expect([...imap.bodies.keys()].every((id) => id.startsWith('8.'))).toBe(
      true,
    );
  });
});
