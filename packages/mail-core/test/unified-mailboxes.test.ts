import type { GmailInboxState } from '../src/gmail-inbox.ts';

import { allMail, gmailArchive } from '../src/gmail-actions.ts';
import { createGmailInbox } from '../src/gmail-inbox.ts';
import { createImapInbox } from '../src/imap-inbox.ts';
import {
  mailboxSidebar,
  unifiedFolders,
  unifiedMailbox,
} from '../src/mailboxes.ts';
import { defaultProfile } from '../src/registration.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticGraph } from '../src/testing/graph-mailbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';

const minute = (n: number) => Date.UTC(2026, 8, 1, 9, n);

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

// One connection of each provider, opened as the Mailboxes registry would.
async function connections() {
  const gmail = createSyntheticGmail();
  const graph = createSyntheticGraph({ pageSize: 50 });
  const imap = createSyntheticImap();
  const bare = createSyntheticImap({ address: 'bare@example.invalid' });
  imap.addFolder('Archive', ['archive']);
  imap.addFolder('Sent Messages', ['sent']);
  imap.addFolder('Junk', ['junk']);
  imap.addFolder('Deleted Messages', ['trash']);
  // Named like Archive but not marked as it, so it is never guessed to be one.
  bare.addFolder('Archive');

  const gmailInbox = createGmailInbox(gmail.native);
  const graphInbox = createGmailInbox(graph.native, {
    provider: 'microsoft-graph',
  });
  const imapInbox = createImapInbox(imap.native);
  const bareInbox = createImapInbox(bare.native);
  const stores = [
    { id: 'gmail', provider: 'gmail' as const, inbox: gmailInbox },
    { id: 'graph', provider: 'microsoft-graph' as const, inbox: graphInbox },
    { id: 'imap', provider: 'imap' as const, inbox: imapInbox },
    { id: 'bare', provider: 'imap' as const, inbox: bareInbox },
  ];
  return { gmail, graph, imap, bare, stores };
}

type Stores = Awaited<ReturnType<typeof connections>>['stores'];

const snapshot = (stores: Stores) =>
  stores.map((store) => ({ ...store, state: store.inbox.getSnapshot() }));

// Opens each mailbox's folders for the role, as the window does, then projects the list.
async function opened(
  stores: Stores,
  role: Parameters<typeof unifiedMailbox>[1],
) {
  for (const mailbox of snapshot(stores)) {
    for (const name of unifiedFolders(mailbox, role) ?? []) {
      if ('openFolder' in mailbox.inbox) {
        await mailbox.inbox.openFolder(name);
      } else if (name !== 'INBOX') {
        await mailbox.inbox.openView(name);
      }
    }
  }
  return unifiedMailbox(snapshot(stores), role, (mailbox, name) =>
    'openFolder' in mailbox.inbox ? mailbox.inbox.folder(name) : undefined,
  );
}

const rows = (list: Awaited<ReturnType<typeof opened>>) =>
  list.entries.map(({ mailbox, message, folder }) => [
    mailbox.id,
    message.subject,
    folder,
  ]);

// The connection folders the sidebar marks as selected.
const selectedFolders = (sidebar: ReturnType<typeof mailboxSidebar>) =>
  sidebar.entries.flatMap((entry) =>
    'section' in entry
      ? entry.section.folders.filter(({ selected }) => selected)
      : [],
  );

describe('unified mailboxes across connections', () => {
  it('interleaves each role across Gmail, Microsoft and IMAP and names a connection without that role', async () => {
    /* oxlint-disable vitest/max-expects -- one journey reads each role from the same connections */
    expect.hasAssertions();
    const { gmail, graph, imap, bare, stores } = await connections();
    const kept = gmail.deliver({ subject: 'Gmail kept', at: minute(1) });
    gmail.archive(kept);
    const welcome = gmail.deliver({ subject: 'Gmail inbox', at: minute(2) });
    const sent = gmail.deliver({ subject: 'Gmail sent', at: minute(5) });
    gmail.archive(sent);
    gmail.setLabel(sent, 'SENT', true);
    const junk = gmail.deliver({ subject: 'Gmail spam', at: minute(6) });
    gmail.setLabel(junk, 'SPAM', true);
    graph.deliver({
      subject: 'Outlook archived',
      folder: 'archive',
      at: minute(3),
    });
    graph.deliver({
      subject: 'Outlook sent',
      folder: 'sentitems',
      at: minute(4),
    });
    imap.deliver('Archive', { subject: 'IMAP archived', received: minute(7) });
    imap.deliver('Sent Messages', {
      subject: 'IMAP sent',
      received: minute(8),
    });
    imap.deliver('INBOX', { subject: 'IMAP inbox', received: minute(9) });
    bare.deliver('Archive', {
      subject: 'Not an archive',
      received: minute(10),
    });
    for (const { inbox } of stores) {
      await inbox.load();
    }
    expect(
      ready(gmailInboxState(stores)).messages.map(({ id }) => id),
    ).toStrictEqual([welcome]);

    const archive = await opened(stores, 'ARCHIVE');
    // Gmail's Archive is mail outside Inbox, Sent and Drafts; a folder merely named Archive is
    // not one, so that connection is missing instead.
    expect(rows(archive)).toStrictEqual([
      ['imap', 'IMAP archived', 'Archive'],
      ['graph', 'Outlook archived', 'ARCHIVE'],
      ['gmail', 'Gmail kept', gmailArchive],
    ]);
    expect(archive.missing.map(({ id }) => id)).toStrictEqual(['bare']);
    expect(archive.failed).toStrictEqual([]);

    // Sent is always offered; a connection without a Sent folder is listed as missing.
    expect(rows(await opened(stores, 'SENT'))).toStrictEqual([
      ['imap', 'IMAP sent', 'Sent Messages'],
      ['gmail', 'Gmail sent', 'SENT'],
      ['graph', 'Outlook sent', 'SENT'],
    ]);

    // All Mail is every message outside Spam and Trash, whatever folder holds it.
    const everything = await opened(stores, allMail);
    expect(
      everything.entries.map(({ message }) => message.subject),
    ).toStrictEqual([
      'Not an archive',
      'IMAP inbox',
      'IMAP sent',
      'IMAP archived',
      'Gmail sent',
      'Outlook sent',
      'Outlook archived',
      'Gmail inbox',
      'Gmail kept',
    ]);
    expect(everything.missing).toStrictEqual([]);

    const spam = await opened(stores, 'SPAM');
    expect(rows(spam)).toStrictEqual([['gmail', 'Gmail spam', 'SPAM']]);
    expect(spam.missing.map(({ id }) => id)).toStrictEqual(['bare']);
  });

  it('drops a Microsoft connection without Archive from that mailbox only, and leaves All inboxes unselected', async () => {
    expect.hasAssertions();
    const { graph, stores } = await connections();
    graph.withoutFolder('archive');
    for (const { inbox } of stores) {
      await inbox.load();
    }
    const mailboxes = snapshot(stores);
    // A Microsoft mailbox without the well-known Archive folder is missing from Archive only.
    const archive = await opened(stores, 'ARCHIVE');
    expect(archive.missing.map(({ id }) => id)).toStrictEqual([
      'graph',
      'bare',
    ]);
    expect(
      mailboxes.map((mailbox) => unifiedFolders(mailbox, 'TRASH')),
    ).toStrictEqual([['TRASH'], ['TRASH'], ['Deleted Messages'], undefined]);

    const sidebar = mailboxSidebar({
      mailboxes,
      connections: [],
      profile: defaultProfile,
      view: { mailbox: 'gmail', folder: 'SPAM', unified: 'TRASH' },
    });
    expect(sidebar.allSelected).toBe(false);
    expect(selectedFolders(sidebar)).toStrictEqual([]);
  });
});

function gmailInboxState(stores: Stores) {
  const [gmail] = stores;
  if (gmail === undefined || !('openView' in gmail.inbox)) {
    throw new Error('Expected the Gmail store');
  }
  return gmail.inbox.getSnapshot();
}
