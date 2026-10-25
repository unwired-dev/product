import assert from 'node:assert/strict';

import {
  allMail,
  gmailAction,
  gmailArchive,
  leavesView,
} from '@private-email/mail-core/gmail-actions';
import {
  createGmailInbox,
  viewMessage,
} from '@private-email/mail-core/gmail-inbox';
import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import {
  mailboxSidebar,
  profileMailboxes,
  unifiedFolders,
  unifiedMailbox,
} from '@private-email/mail-core/mailboxes';
import { defaultProfile } from '@private-email/mail-core/registration';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';

const minute = (n: number) => Date.UTC(2026, 8, 1, 9, n);

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
    gmail.deliver({ subject: 'Gmail inbox', at: minute(2) });
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

  it('lists only the window Profile’s connections', async () => {
    expect.hasAssertions();
    const { gmail, imap, stores } = await connections();
    const personal = gmail.deliver({ subject: 'Personal sent', at: minute(1) });
    gmail.archive(personal);
    gmail.setLabel(personal, 'SENT', true);
    imap.deliver('Sent Messages', {
      subject: 'Work sent',
      received: minute(2),
    });
    for (const { inbox } of stores) {
      await inbox.load();
    }
    // The IMAP connection belongs to the Work Profile; the others to the default one.
    const [gmailStore, graphStore, imapStore, bareStore] = stores;
    const registered = [
      { ...gmailStore!, profile: defaultProfile },
      { ...graphStore!, profile: defaultProfile },
      { ...imapStore!, profile: 'work' },
      { ...bareStore!, profile: defaultProfile },
    ];
    const scoped = (profile: string) => profileMailboxes(registered, profile);
    expect(rows(await opened(scoped('work'), 'SENT'))).toStrictEqual([
      ['imap', 'Work sent', 'Sent Messages'],
    ]);
    expect(rows(await opened(scoped(defaultProfile), 'SENT'))).toStrictEqual([
      ['gmail', 'Personal sent', 'SENT'],
    ]);
  });

  it.each([
    { role: 'SENT', view: 'SENT', kept: 'SENT' },
    { role: 'ARCHIVE', view: gmailArchive, kept: 'STARRED' },
  ] as const)(
    'moves Gmail mail from $role without removing a system or synthetic label',
    async ({ role, view, kept }) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail();
      const destination = gmail.createLabel('Receipts');
      const id = gmail.deliver({ subject: 'Saved receipt' });
      gmail.archive(id);
      gmail.setLabel(id, kept, true);
      const inbox = createGmailInbox(gmail.native);
      await inbox.load();
      const list = await opened(
        [{ id: 'gmail', provider: 'gmail', inbox }],
        role,
      );
      expect(list.entries).toHaveLength(1);
      const state = inbox.getSnapshot();
      assert.ok(state.kind === 'ready');
      const message = viewMessage(state, id, view);
      assert.ok(message !== undefined);
      await inbox.organize(message, gmailAction.move(destination, view));
      expect(gmail.modifies.at(-1)).toStrictEqual({
        id,
        add: [destination],
        remove: ['INBOX'],
      });
      expect(gmail.labelsOf(id)).toContain(destination);
      expect(gmail.labelsOf(id)).toContain(kept);
    },
  );

  it('moves Microsoft Sent mail out of its source folder', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph();
    const destination = graph.createFolder('Receipts');
    const id = graph.deliver({ subject: 'Sent receipt', folder: 'sentitems' });
    const inbox = createGmailInbox(graph.native, {
      provider: 'microsoft-graph',
    });
    await inbox.load();
    await inbox.openView('SENT');
    const state = inbox.getSnapshot();
    assert.ok(state.kind === 'ready');
    const message = viewMessage(state, id, 'SENT');
    assert.ok(message !== undefined);
    assert.ok(message.labels !== undefined);
    const action = gmailAction.move(destination, 'SENT', 'microsoft-graph');
    expect(leavesView('SENT', message.labels, action)).toBe(true);
    await inbox.organize(message, action);
    const after = inbox.getSnapshot();
    assert.ok(after.kind === 'ready');
    expect(viewMessage(after, id, 'SENT')).toBeUndefined();
    expect(graph.folderOf(id)).toBe(destination);
  });
});
