import type {
  GmailInboxState,
  GmailView,
} from '@private-email/mail-core/gmail-inbox';

import { gmailAction } from '@private-email/mail-core/gmail-actions';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import {
  gmailViewName,
  mailboxSidebar,
} from '@private-email/mail-core/mailboxes';
import { defaultProfile } from '@private-email/mail-core/registration';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';

type Graph = ReturnType<typeof createSyntheticGraph>;
type Inbox = ReturnType<typeof createGmailInbox>;

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

const view = (inbox: Inbox, label: string): GmailView => {
  const found = ready(inbox.getSnapshot()).views?.find(
    (entry) => entry.label === label,
  );
  if (found === undefined) {
    throw new Error(`View ${label} is not open`);
  }
  return found;
};

const ids = (messages: ReadonlyArray<Readonly<{ id: string }>>) =>
  messages.map(({ id }) => id);

const first = <A>(messages: readonly A[]): A => {
  const [message] = messages;
  if (message === undefined) {
    throw new Error('Expected a listed message');
  }
  return message;
};

const opened = async (native: Graph['native']) => {
  const inbox = createGmailInbox(native, { provider: 'microsoft-graph' });
  await inbox.load();
  return inbox;
};

const openViews = (inbox: Inbox) =>
  ready(inbox.getSnapshot()).views?.map(({ label }) => label);

// The folder rows the sidebar shows for the mailbox.
const sidebarFolders = (inbox: Inbox) =>
  mailboxSidebar({
    mailboxes: [
      {
        id: 'casey',
        provider: 'microsoft-graph',
        state: inbox.getSnapshot(),
      },
    ],
    connections: [],
    profile: defaultProfile,
    view: { mailbox: 'casey' },
  }).entries.flatMap((entry) =>
    'section' in entry ? entry.section.folders.map(({ name }) => name) : [],
  );

// Full listings of a folder, apart from its delta rounds and single-message reads.
const listings = (graph: Graph, folder: string) =>
  graph.requests.filter(({ pathname }) =>
    pathname.endsWith(`/mailFolders/${folder}/messages`),
  );

// Graph answers every read of `folder` with a server error while `failing` says so.
const failingFolder = (
  graph: Graph,
  folder: string,
  failing: () => boolean,
): Graph['native'] => ({
  ...graph.native,
  graphRequest: (url, owner) =>
    failing() && decodeURIComponent(url).includes(folder)
      ? Promise.resolve({ status: 503, body: '{}' })
      : graph.native.graphRequest(url, owner),
});

// A provider throttles redundant delta polls within the same synchronization.
const throttledPolling = (
  graph: Graph,
  read: Set<string>,
): Graph['native'] => ({
  ...graph.native,
  graphRequest: (url, owner) => {
    const repeated = read.has(url);
    read.add(url);
    return repeated && url.includes('/messages/delta?')
      ? Promise.resolve({ status: 429, body: '{}' })
      : graph.native.graphRequest(url, owner);
  },
});

describe('browsing Microsoft mail folders', () => {
  /* oxlint-disable vitest/max-expects -- each journey follows one folder through its changes */
  it('lists each folder from its own delta checkpoint and keeps it current through changes and relaunch', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ pageSize: 50 });
    const projects = graph.createFolder('Projects');
    const launch = graph.createFolder('Launch', projects);
    const welcome = graph.deliver({ subject: 'Welcome' });
    const note = graph.deliver({
      subject: 'Sent note',
      folder: 'sentitems',
      isRead: true,
    });
    const plan = graph.deliver({ subject: 'Plan', folder: projects });
    const brief = graph.deliver({ subject: 'Brief', folder: launch });
    const offer = graph.deliver({ subject: 'Offer', folder: 'junkemail' });
    const inbox = await opened(graph.native);
    // Inbox, the well-known folders, then the mailbox's own folders by path.
    expect(sidebarFolders(inbox)).toStrictEqual([
      inboxFolder,
      'SENT',
      'ARCHIVE',
      'SPAM',
      'TRASH',
      projects,
      launch,
    ]);
    expect(
      ready(inbox.getSnapshot()).labels.map(({ name }) => name),
    ).toStrictEqual(['Projects', 'Projects / Launch']);

    await inbox.openView(projects);
    expect(view(inbox, projects)).toMatchObject({
      status: 'current',
      limited: true,
    });
    expect(view(inbox, projects).messages).toStrictEqual([
      expect.objectContaining({ id: plan, labels: [projects, 'UNREAD'] }),
    ]);
    await inbox.openView(launch);
    expect(ids(view(inbox, launch).messages)).toStrictEqual([brief]);
    await inbox.openView('SENT');
    expect(ids(view(inbox, 'SENT').messages)).toStrictEqual([note]);
    expect(openViews(inbox)).toStrictEqual(['SENT', launch, projects]);
    expect(ids(ready(inbox.getSnapshot()).messages)).toStrictEqual([welcome]);

    // Changes made in Outlook reach each saved folder through its own delta link.
    const kickoff = graph.deliver({ subject: 'Kickoff', folder: projects });
    graph.move(welcome, projects);
    graph.move(plan, launch);
    const listed = listings(graph, projects).length;
    const relaunched = await opened(graph.native);
    expect(ids(view(relaunched, projects).messages)).toStrictEqual([
      kickoff,
      welcome,
    ]);
    expect(ids(view(relaunched, launch).messages)).toStrictEqual([brief, plan]);
    expect(ready(relaunched.getSnapshot()).messages).toStrictEqual([]);
    // Relaunch read each folder's changes; none was listed again.
    expect(listings(graph, projects)).toHaveLength(listed);

    // Deleting from a folder view shows the message in Deleted Items, which restores it.
    const deleting = relaunched.organize(
      first(view(relaunched, projects).messages),
      gmailAction.trash,
    );
    expect(ids(view(relaunched, projects).messages)).toStrictEqual([welcome]);
    await deleting;
    expect(graph.folderOf(kickoff)).toBe('deleteditems');
    await relaunched.openView('TRASH');
    const deleted = first(view(relaunched, 'TRASH').messages);
    expect(deleted.id).toBe(kickoff);
    const restoring = relaunched.organize(
      deleted,
      gmailAction.restore('TRASH'),
    );
    expect(view(relaunched, 'TRASH').messages).toStrictEqual([]);
    expect(ids(ready(relaunched.getSnapshot()).messages)).toStrictEqual([
      kickoff,
    ]);
    await restoring;
    expect(graph.folderOf(kickoff)).toBe('inbox');

    // Junk Email restores to the Inbox too.
    await relaunched.openView('SPAM');
    await relaunched.organize(
      first(view(relaunched, 'SPAM').messages),
      gmailAction.restore('SPAM'),
    );
    expect(graph.folderOf(offer)).toBe('inbox');
    expect(view(relaunched, 'SPAM').messages).toStrictEqual([]);
    expect(ids(ready(relaunched.getSnapshot()).messages)).toContain(offer);
  });

  it('finishes opening a folder without polling quiet folders again, then reads their later changes', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ pageSize: 1 });
    const projects = graph.createFolder('Projects');
    const travel = graph.createFolder('Travel');
    const flight = graph.deliver({ subject: 'Flight', folder: travel });
    const hotel = graph.deliver({ subject: 'Hotel', folder: travel });
    const read = new Set<string>();
    const inbox = await opened(throttledPolling(graph, read));
    read.clear();
    await inbox.openView(projects);
    read.clear();
    await inbox.openView(travel);
    expect(ready(inbox.getSnapshot()).sync).toBe('current');
    expect(view(inbox, projects).status).toBe('current');
    expect(view(inbox, travel).status).toBe('current');
    expect(ids(view(inbox, travel).messages)).toStrictEqual([hotel, flight]);

    // A new synchronization still reads changes since the quiet checkpoint.
    const plan = graph.deliver({ subject: 'Plan', folder: projects });
    read.clear();
    await inbox.load();
    expect(ready(inbox.getSnapshot()).sync).toBe('current');
    expect(ids(view(inbox, projects).messages)).toStrictEqual([plan]);
  });

  it('keeps a folder whose read fails with its saved messages, and drops a folder Outlook removed', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph();
    const projects = graph.createFolder('Projects');
    const travel = graph.createFolder('Travel');
    const plan = graph.deliver({ subject: 'Plan', folder: projects });
    graph.deliver({ subject: 'Flight', folder: travel });
    let failing = false;
    const inbox = await opened(failingFolder(graph, projects, () => failing));
    await inbox.openView(projects);
    await inbox.openView(travel);
    expect(view(inbox, projects).status).toBe('current');

    failing = true;
    graph.deliver({ subject: 'Later plan', folder: projects });
    const arrival = graph.deliver({ subject: 'New arrival' });
    await inbox.load();
    // The folder that could not be read says so and keeps its saved mail; the Inbox stays current.
    expect(view(inbox, projects).status).toBe('failed');
    expect(ids(view(inbox, projects).messages)).toStrictEqual([plan]);
    expect(ready(inbox.getSnapshot()).sync).toBe('current');
    expect(ids(ready(inbox.getSnapshot()).messages)).toStrictEqual([arrival]);
    failing = false;
    await inbox.load();
    expect(view(inbox, projects).status).toBe('current');
    expect(view(inbox, projects).messages).toHaveLength(2);

    graph.deleteFolder(projects);
    await inbox.load();
    expect(openViews(inbox)).toStrictEqual([travel]);
    expect(sidebarFolders(inbox)).not.toContain(projects);
    // A window that chose the removed folder falls back to the Inbox; reopening it opens nothing.
    expect(
      gmailViewName(ready(inbox.getSnapshot()), projects, 'microsoft-graph'),
    ).toBe(inboxFolder);
    await inbox.openView(projects);
    expect(openViews(inbox)).toStrictEqual([travel]);
  });

  it('keeps a full folder full when a message leaves it', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ pageSize: 50 });
    const archived = Array.from({ length: 201 }, (_, index) =>
      graph.deliver({ subject: `Archived ${index}`, folder: 'archive' }),
    );
    const inbox = await opened(graph.native);
    await inbox.openView('ARCHIVE');
    expect(view(inbox, 'ARCHIVE').messages).toHaveLength(200);
    expect(ids(view(inbox, 'ARCHIVE').messages)).not.toContain(archived[0]);
    const newest = first(view(inbox, 'ARCHIVE').messages);
    graph.restore(newest.id);
    await inbox.load();
    // The oldest message, which the folder's delta never names, fills the place the restored one left.
    expect(view(inbox, 'ARCHIVE').messages).toHaveLength(200);
    expect(ids(view(inbox, 'ARCHIVE').messages)).toContain(archived[0]);
    expect(ids(ready(inbox.getSnapshot()).messages)).toContain(newest.id);
  });

  it('offers only the well-known folders the mailbox has', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph();
    graph.withoutFolder('archive');
    const inbox = await opened(graph.native);
    expect(sidebarFolders(inbox)).toStrictEqual([
      inboxFolder,
      'SENT',
      'SPAM',
      'TRASH',
    ]);
    await inbox.openView('ARCHIVE');
    expect(openViews(inbox)).toBeUndefined();
  });
  /* oxlint-enable vitest/max-expects */
});
