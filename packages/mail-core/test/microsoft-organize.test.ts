import type { GmailInboxState, GmailMessage } from '../src/gmail-inbox.ts';

import { gmailAction, restoreAfter } from '../src/gmail-actions.ts';
import { createGmailInbox } from '../src/gmail-inbox.ts';
import { createGmailSearch, createMailboxes } from '../src/mailboxes.ts';
import { createRegistration, defaultProfile } from '../src/registration.ts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '../src/testing/gmail-mailbox.ts';
import { createSyntheticGraph } from '../src/testing/graph-mailbox.ts';
import { createRegistrationScenario } from '../src/testing/registration-scenarios.ts';
import { syntheticMailboxes } from '../src/testing/registration-vault.ts';

type Graph = ReturnType<typeof createSyntheticGraph>;
type Inbox = ReturnType<typeof createGmailInbox>;

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

const required = <A>(value: A | null | undefined, name: string): A => {
  if (value === undefined || value === null) {
    throw new Error(`Expected ${name}`);
  }
  return value;
};

// A search page's results, labeled with where each message is.
const results = (page: Awaited<ReturnType<Inbox['searchGmail']>>) => {
  if (page?.kind !== 'found') {
    throw new Error('Expected search results');
  }
  return page;
};

const message = (inbox: Inbox, id: string): GmailMessage =>
  required(
    ready(inbox.getSnapshot()).messages.find((each) => each.id === id),
    `message ${id} in the Inbox`,
  );

const ids = (inbox: Inbox) =>
  ready(inbox.getSnapshot()).messages.map(({ id }) => id);

const microsoftInbox = (graph: Graph) =>
  createGmailInbox(graph.native, { provider: 'microsoft-graph' });

const opened = async (graph: Graph) => {
  const inbox = microsoftInbox(graph);
  await inbox.load();
  return inbox;
};

describe('organizing Microsoft mail through Graph', () => {
  it('refills a full Inbox after a confirmed archive and still allows Undo', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 201, pageSize: 50 });
    const inbox = await opened(graph);
    const target = required(
      ready(inbox.getSnapshot()).messages[0],
      'a message',
    );
    await inbox.organize(target, gmailAction.archive);
    expect(ids(inbox)).toHaveLength(200);
    expect(ids(inbox)).not.toContain(target.id);
    const relaunched = await opened(graph);
    expect(ids(relaunched)).toHaveLength(200);
    await inbox.organize(
      target,
      required(restoreAfter(gmailAction.archive, target.labels), 'Undo'),
    );
    expect(ids(inbox)).toHaveLength(200);
    expect(ids(inbox)).toContain(target.id);
  });

  it('moves mail between Graph folders and changes read state, through an outage and relaunch', async () => {
    /* oxlint-disable vitest/max-expects -- One journey follows each change through an outage, relaunch and Undo. */
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 5 });
    const travel = graph.createFolder('Travel');
    // A v1 cache without folder paths acquires them even when folder IDs and names are unchanged.
    const cache = await graph.native.openMailbox();
    await graph.native.commitMailbox(
      cache,
      cache.revision,
      JSON.stringify({
        version: 1,
        messages: [],
        labels: [{ id: travel, name: 'Travel' }],
        checkpoint: { kind: 'graph-listing' },
      }),
    );
    const inbox = await opened(graph);
    // Move to offers the mailbox's own folders, not its well-known ones.
    expect(ready(inbox.getSnapshot()).labels).toStrictEqual([
      { id: travel, name: 'Travel', path: ['Travel'] },
    ]);
    const [read = '', archived = '', trashed = '', junk = '', moved = ''] =
      ids(inbox);

    // Graph cannot be reached: the change shows at once and waits, saved on this device.
    graph.failModify({ code: 'unavailable' });
    const reading = inbox.organize(message(inbox, read), gmailAction.read);
    expect(message(inbox, read).unread).toBe(false);
    await reading;
    expect(ready(inbox.getSnapshot())).toMatchObject({
      sync: 'retry',
      pending: 1,
    });

    // A relaunch sends the saved change again, and Graph's reply settles it.
    const relaunched = await opened(graph);
    expect(ready(relaunched.getSnapshot()).labels).toStrictEqual(
      ready(inbox.getSnapshot()).labels,
    );
    expect(ready(relaunched.getSnapshot())).toMatchObject({
      sync: 'current',
      pending: 0,
    });
    expect(message(relaunched, read).labels).toStrictEqual(['INBOX']);
    expect(graph.modifies).toStrictEqual([
      { message: read, read: true },
      { message: read, read: true },
    ]);

    await relaunched.organize(
      message(relaunched, archived),
      gmailAction.archive,
    );
    await relaunched.organize(message(relaunched, trashed), gmailAction.trash);
    await relaunched.organize(message(relaunched, junk), gmailAction.spam);
    await relaunched.organize(
      message(relaunched, moved),
      gmailAction.move(travel),
    );
    expect([archived, trashed, junk, moved].map(graph.folderOf)).toStrictEqual([
      'archive',
      'deleteditems',
      'junkemail',
      travel,
    ]);
    expect(ids(relaunched)).toStrictEqual([read]);

    // Undo moves the message back to the Inbox.
    const notice = required(ready(relaunched.getSnapshot()).notice, 'a move');
    await relaunched.organize(
      notice.message,
      required(restoreAfter(notice.action, notice.message.labels), 'Undo'),
    );
    expect(graph.folderOf(moved)).toBe('inbox');
    expect(ids(relaunched)).toStrictEqual([read, moved]);
    expect(graph.modifies.slice(2)).toStrictEqual([
      { message: archived, folder: 'archive' },
      { message: trashed, folder: 'deleteditems' },
      { message: junk, folder: 'junkemail' },
      { message: moved, folder: travel },
      { message: moved, folder: 'inbox' },
    ]);
  });

  it.each([
    // Graph applied the change, but its reply never arrived: the message's folder settles it.
    { failure: { lost: true } as const, requests: 1 },
    { failure: { status: 429 }, requests: 2 },
    { failure: { status: 503 }, requests: 2 },
  ])(
    'archives once after $failure, without moving the message twice',
    async ({ failure, requests }) => {
      expect.hasAssertions();
      const graph = createSyntheticGraph({ messages: 2 });
      const inbox = await opened(graph);
      const [target = '', other = ''] = ids(inbox);
      graph.failModify(failure);

      await inbox.organize(message(inbox, target), gmailAction.archive);
      expect(ready(inbox.getSnapshot()).pending).toBe(1);
      const relaunched = await opened(graph);

      expect(ready(relaunched.getSnapshot()).pending).toBe(0);
      expect(ids(relaunched)).toStrictEqual([other]);
      expect(graph.folderOf(target)).toBe('archive');
      expect(graph.modifies).toHaveLength(requests);
    },
  );

  it('shows mail as Graph has it when a change finds the message or folder gone', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 2 });
    const travel = graph.createFolder('Travel');
    const inbox = await opened(graph);
    const [deleted = '', kept = ''] = ids(inbox);

    // Deleted for good in Outlook meanwhile: Graph no longer has it, and it leaves the Inbox.
    graph.purge(deleted);
    await inbox.organize(message(inbox, deleted), gmailAction.read);
    expect(ready(inbox.getSnapshot()).notice).toMatchObject({
      kind: 'rejected',
      action: gmailAction.read,
    });
    expect(ids(inbox)).toStrictEqual([kept]);

    // A folder removed in Outlook refuses the move; the message stays where Graph has it.
    graph.deleteFolder(travel);
    await inbox.organize(message(inbox, kept), gmailAction.move(travel));
    expect(ready(inbox.getSnapshot())).toMatchObject({
      pending: 0,
      notice: { kind: 'rejected' },
    });
    expect(ids(inbox)).toStrictEqual([kept]);
    expect(graph.folderOf(kept)).toBe('inbox');
  });

  it('retries Archive when Outlook moved the message to Trash during an interrupted attempt', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 1 });
    const inbox = await opened(graph);
    const [target = ''] = ids(inbox);
    graph.failModify({ status: 503 });
    await inbox.organize(message(inbox, target), gmailAction.archive);
    graph.remove(target);

    const relaunched = await opened(graph);
    expect(ready(relaunched.getSnapshot()).pending).toBe(0);
    expect(graph.folderOf(target)).toBe('archive');
    expect(graph.modifies).toHaveLength(2);
  });

  it.each([
    { missing: 'parentFolderId', fields: { isRead: true } },
    { missing: 'isRead', fields: { parentFolderId: 'AQMkFolder-inbox=' } },
  ])(
    'keeps an action pending when its Graph reply omits $missing',
    async ({ fields }) => {
      expect.hasAssertions();
      const graph = createSyntheticGraph({ messages: 1 });
      const inbox = createGmailInbox(
        {
          ...graph.native,
          graphModify: ({ message: id }) =>
            Promise.resolve({
              status: 200,
              body: JSON.stringify({
                id,
                ...fields,
              }),
            }),
        },
        { provider: 'microsoft-graph' },
      );
      await inbox.load();
      const [target = ''] = ids(inbox);
      await inbox.organize(message(inbox, target), gmailAction.read);

      expect(ready(inbox.getSnapshot())).toMatchObject({
        pending: 1,
        sync: 'retry',
      });
      expect(ids(inbox)).toStrictEqual([target]);
      const relaunched = await opened(graph);
      expect(ready(relaunched.getSnapshot()).pending).toBe(0);
      expect(message(relaunched, target).unread).toBe(false);
    },
  );

  it('keeps interrupted intent pending when placement read-back is incomplete', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 1 });
    const inbox = await opened(graph);
    const [target = ''] = ids(inbox);
    graph.failModify({ status: 503 });
    await inbox.organize(message(inbox, target), gmailAction.archive);
    const readBack = vi.spyOn(graph.native, 'graphRequest');
    readBack.mockResolvedValueOnce({
      status: 200,
      body: JSON.stringify({ id: target }),
    });
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({
      pending: 1,
      sync: 'retry',
    });
    expect(graph.modifies).toHaveLength(1);

    readBack.mockRestore();
    await inbox.load();
    expect(ready(inbox.getSnapshot()).pending).toBe(0);
    expect(graph.folderOf(target)).toBe('archive');
  });

  it('keeps a change saved and asks for Microsoft again when the grant cannot organize mail', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 1 });
    const inbox = await opened(graph);
    const [target = ''] = ids(inbox);

    // A connection authorized only to read mail: Graph refuses the write.
    graph.failModify({ status: 403 });
    await inbox.organize(message(inbox, target), gmailAction.trash);

    expect(ready(inbox.getSnapshot())).toMatchObject({
      sync: 'authentication',
      pending: 1,
    });
    expect(graph.folderOf(target)).toBe('inbox');
    // Once Microsoft allows organizing again, the saved change is sent.
    const authorized = await opened(graph);
    expect(ready(authorized.getSnapshot()).pending).toBe(0);
    expect(graph.folderOf(target)).toBe('deleteditems');
  });

  it('lists nested folders by their paths and says when some are left out', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({
      messages: 1,
      inboxName: 'Posteingang',
    });
    const travel = graph.createFolder('Travel');
    const lisbon = graph.createFolder('Lisbon', travel);
    const projects = graph.createFolder('Projects', 'inbox');
    graph.createFolder('Travel', projects);
    const inbox = await opened(graph);
    const [target = ''] = ids(inbox);

    // Equal names stay apart by their paths, including folders inside the Inbox. Their paths
    // name the Inbox `INBOX`, as its display name follows the mailbox's locale.
    expect(ready(inbox.getSnapshot())).toMatchObject({
      labels: [
        {
          id: projects,
          name: 'Posteingang / Projects',
          path: ['INBOX', 'Projects'],
        },
        {
          name: 'Posteingang / Projects / Travel',
          path: ['INBOX', 'Projects', 'Travel'],
        },
        { id: travel, name: 'Travel', path: ['Travel'] },
        { id: lisbon, name: 'Travel / Lisbon', path: ['Travel', 'Lisbon'] },
      ],
    });
    await inbox.organize(message(inbox, target), gmailAction.move(lisbon));
    expect(graph.folderOf(target)).toBe(lisbon);

    for (let index = 0; index < 250; index += 1) {
      graph.createFolder(`Folder ${index}`);
    }
    const reopened = await opened(graph);
    const crowded = ready(reopened.getSnapshot());
    expect({
      listed: crowded.labels.length,
      limited: crowded.labelsLimited,
    }).toStrictEqual({ listed: 250, limited: true });
  });

  it('offers only the changes Graph can make', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 1 });
    const inbox = await opened(graph);
    const [target = ''] = ids(inbox);

    await inbox.organize(message(inbox, target), gmailAction.star);
    await inbox.organize(message(inbox, target), gmailAction.label('Travel'));

    expect(ready(inbox.getSnapshot()).pending).toBe(0);
    expect(graph.modifies).toStrictEqual([]);
    expect(message(inbox, target).labels).toStrictEqual(['INBOX', 'UNREAD']);
  });

  it.each([
    { folder: 'archive', action: gmailAction.archive },
    { folder: 'deleteditems', action: gmailAction.trash },
    { folder: 'junkemail', action: gmailAction.spam },
  ])(
    'does not offer or queue $action.kind when its folder is absent',
    async ({ folder, action }) => {
      expect.hasAssertions();
      const graph = createSyntheticGraph({ messages: 1 });
      graph.withoutFolder(folder);
      const inbox = await opened(graph);
      const [target = ''] = ids(inbox);
      expect(ready(inbox.getSnapshot()).unavailableActions).toContain(
        action.kind,
      );
      await inbox.organize(message(inbox, target), action);
      expect(ready(inbox.getSnapshot()).pending).toBe(0);
      expect(graph.modifies).toStrictEqual([]);
    },
  );

  it('searches every folder, labels results by where they are, and continues on the next page', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ pageSize: 1 });
    const inboxed = graph.deliver({ subject: 'Quarterly plan', isRead: true });
    const archived = graph.deliver({ subject: 'Quarterly review' });
    const inbox = await opened(graph);
    await inbox.organize(message(inbox, archived), gmailAction.archive);

    // The query reaches Graph quoted, with its own quote escaped.
    await expect(
      inbox.searchGmail('quarterly "plan', undefined),
    ).resolves.toStrictEqual({ kind: 'found', messages: [] });
    const page = results(await inbox.searchGmail('quarterly', undefined));
    const next = results(await inbox.searchGmail('quarterly', page.next));
    expect({
      searches: graph.searches,
      found: [...page.messages, ...next.messages].map(({ id, labels }) => [
        id,
        labels,
      ]),
    }).toStrictEqual({
      searches: [String.raw`"quarterly \"plan"`, '"quarterly"', '"quarterly"'],
      found: [
        [archived, ['ARCHIVE', 'UNREAD']],
        [inboxed, ['INBOX']],
      ],
    });
    // A page token this Inbox never issued reaches no provider.
    const before = graph.requests.length;
    await expect(
      inbox.searchGmail('quarterly', 'https://example.invalid/me/messages'),
    ).resolves.toStrictEqual({ kind: 'unavailable', reason: 'failed' });
    expect(graph.requests).toHaveLength(before);
  });

  it('sends each change only to the connection that showed the message', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'other@example.invalid' });
    const graph = createSyntheticGraph();
    gmail.deliver({ subject: 'From Gmail' });
    graph.deliver({ subject: 'From Outlook' });
    const synthetic = await createRegistrationScenario('registration-success');
    const registration = createRegistration(synthetic.vault);
    await registration.register('apple');
    await registration.addMailbox('microsoft-graph');
    await registration.addMailbox('gmail', true);
    const mailboxes = createMailboxes(
      syntheticConnections({
        [syntheticMailboxes['other@example.invalid']]: gmail,
        [syntheticMailboxes['casey@example.invalid']]: graph,
      }),
      registration,
    );
    await mailboxes.load();
    const [microsoft, google] = mailboxes.getSnapshot();
    const outlook = required(microsoft, 'the Microsoft mailbox').inbox;
    const gmailInbox = required(google, 'the Gmail mailbox').inbox;
    const [fromOutlook = ''] = ids(outlook);
    const [fromGmail = ''] = ids(gmailInbox);

    await outlook.organize(message(outlook, fromOutlook), gmailAction.read);
    await gmailInbox.organize(
      message(gmailInbox, fromGmail),
      gmailAction.archive,
    );
    // A message shown by one connection is never organized through another.
    await gmailInbox.organize(message(outlook, fromOutlook), gmailAction.trash);

    expect(graph.modifies).toStrictEqual([
      { message: fromOutlook, read: true },
    ]);
    expect(gmail.modifies).toStrictEqual([
      { id: fromGmail, add: [], remove: ['INBOX'] },
    ]);
    const search = createGmailSearch(mailboxes.getSnapshot(), 'From', {
      profile: defaultProfile,
    });
    await search.search();
    expect(
      search
        .getSnapshot()
        .found?.results.map(({ mailbox, message: found }) => [
          mailbox.provider,
          found.subject,
        ]),
    ).toStrictEqual(
      expect.arrayContaining([
        ['microsoft-graph', 'From Outlook'],
        ['gmail', 'From Gmail'],
      ]),
    );
  });
});
