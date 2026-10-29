import type { GmailInboxState } from '@private-email/mail-core/gmail-inbox';

import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';
import * as Schema from 'effect/Schema';

import { withNativeHistory } from './native-history-store.ts';

type Graph = ReturnType<typeof createSyntheticGraph>;
type Inbox = ReturnType<typeof createGmailInbox>;

const createGraph = (folderPageSize?: number) =>
  withNativeHistory(
    createSyntheticGraph({
      pageSize: 50,
      ...(folderPageSize === undefined ? {} : { folderPageSize }),
    }),
  );

// Stop background work before the signed storage process's earlier-registered teardown closes it.
const createInbox = (native: Graph['native']) => {
  const inbox = createGmailInbox(native, { provider: 'microsoft-graph' });
  onTestFinished(() => inbox.forget());
  return inbox;
};

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

const progress = (inbox: Inbox) => ready(inbox.getSnapshot()).history;

const backfilled = async (inbox: Inbox) => {
  await vi.waitFor(
    () => {
      expect(progress(inbox)?.complete).toBe(true);
    },
    { timeout: 60_000 },
  );
};

// Delivers `count` messages to `folder`, a minute apart.
const delivered = (graph: Graph, count: number, folder: string) =>
  Array.from({ length: count }, (_, index) =>
    graph.deliver({
      subject: `${folder} ${index}`,
      folder,
      isRead: index % 2 === 1,
    }),
  );

const savedHistory = Schema.decodeUnknownSync(
  Schema.fromJsonString(
    Schema.Struct({
      graphHistory: Schema.Struct({
        folders: Schema.Array(
          Schema.Struct({
            folder: Schema.String,
            history: Schema.Struct({
              current: Schema.Struct({
                segments: Schema.Array(Schema.Struct({ name: Schema.String })),
              }),
              previous: Schema.optionalKey(
                Schema.Struct({
                  segments: Schema.Array(
                    Schema.Struct({ name: Schema.String }),
                  ),
                }),
              ),
              changes: Schema.Array(
                Schema.Struct({
                  id: Schema.String,
                  message: Schema.optionalKey(
                    Schema.Struct({ id: Schema.String }),
                  ),
                }),
              ),
            }),
          }),
        ),
      }),
    }),
  ),
);
const segmentIds = Schema.decodeUnknownSync(
  Schema.fromJsonString(Schema.Array(Schema.Struct({ id: Schema.String }))),
);

// The download counts each published Inbox state shows, until `stop` is called.
const shownCounts = (inbox: Inbox) => {
  const counts: number[] = [];
  const stop = inbox.subscribe(() => {
    const count = progress(inbox)?.downloaded;
    if (count !== undefined) {
      counts.push(count);
    }
  });
  return { counts, stop };
};

// The message IDs the saved history holds for each folder, from its segments with the recorded
// changes applied, as the native store returns them.
const downloaded = async (graph: Graph) => {
  const scope = await graph.native.openMailbox();
  const { graphHistory } = savedHistory(scope.document ?? '');
  const folders = new Map<string, string[]>();
  for (const { folder, history } of graphHistory.folders) {
    const listed: string[] = [];
    for (const { name } of (history.previous ?? history.current).segments) {
      const { document } = await graph.native.openMailboxSegment(scope, name);
      listed.push(...segmentIds(document ?? '').map(({ id }) => id));
    }
    const changed = new Map(
      history.changes.map(({ id, message }) => [id, message] as const),
    );
    const kept = listed.filter(
      (id) => !changed.has(id) || changed.get(id) !== undefined,
    );
    const added = [...changed].flatMap(([id, message]) =>
      message === undefined || kept.includes(id) ? [] : [id],
    );
    folders.set(folder, [...kept, ...added].toSorted());
  }
  return folders;
};

// The history listings Graph was asked for, by the receipt each began below.
const historyListings = (graph: Graph) =>
  graph.requests
    .filter(
      ({ pathname, searchParams }) =>
        pathname.endsWith('/messages') &&
        searchParams.get('$top') === '50' &&
        !searchParams.has('$skip'),
    )
    .map(
      ({ pathname, searchParams }) =>
        `${pathname.split('/').at(-2)} ${searchParams.get('$filter') ?? ''}`,
    );

// How many Inbox pages of 50 Graph was asked for, including continuations.
const inboxPages = (graph: Graph) =>
  graph.requests.filter(
    ({ pathname, searchParams }) =>
      pathname.endsWith('/inbox/messages') && searchParams.get('$top') === '50',
  ).length;

const sorted = (ids: readonly string[]) => ids.toSorted();

// Graph answers history listings after the first `pages` with the status `refusal()` gives, as
// when it is unavailable, throttles or refuses the grant partway through a folder.
const refusingAfter = (
  graph: Graph,
  pages: number,
  refusal: () => number | undefined,
): Graph['native'] => {
  let listed = 0;
  return {
    ...graph.native,
    graphRequest: (url, owner) => {
      const status = refusal();
      if (/(?:\$|%24)top=50/u.test(url) && status !== undefined) {
        listed += 1;
        if (listed > pages) {
          return Promise.resolve({ status, body: '{}' });
        }
      }
      return graph.native.graphRequest(url, owner);
    },
  };
};

// Graph answers each continuation of a folder list, which Move to never reads, with the status
// `refusal()` gives.
const refusingFolderPages = (
  graph: Graph,
  refusal: () => number | undefined,
): Graph['native'] => ({
  ...graph.native,
  graphRequest: (url, owner) => {
    const status = refusal();
    return status !== undefined && /mailFolders\?.*(?:\$|%24)skip=/u.test(url)
      ? Promise.resolve({ status, body: '{}' })
      : graph.native.graphRequest(url, owner);
  },
});

describe('microsoft historical metadata backfill', () => {
  it('downloads each folder after the Inbox is usable and reports progress', async () => {
    expect.hasAssertions();
    const graph = createGraph();
    const projects = graph.createFolder('Projects');
    const inboxIds = delivered(graph, 260, 'inbox');
    const sentIds = delivered(graph, 30, 'sentitems');
    const projectIds = delivered(graph, 120, projects);
    delivered(graph, 5, 'deleteditems');
    const inbox = createInbox(graph.native);
    await inbox.load();
    expect(ready(inbox.getSnapshot()).messages).toHaveLength(200);
    await backfilled(inbox);
    expect(progress(inbox)).toStrictEqual({
      downloaded: 410,
      total: 410,
      complete: true,
    });
    const folders = await downloaded(graph);
    // Deleted Items stays out, as Gmail's Trash does.
    expect(Object.fromEntries(folders)).toStrictEqual({
      INBOX: sorted(inboxIds),
      SENT: sorted(sentIds),
      ARCHIVE: [],
      [projects]: sorted(projectIds),
    });
  });

  it('lists messages sharing one receipt across pages once each', async () => {
    expect.hasAssertions();
    const graph = createGraph();
    const ids = Array.from({ length: 120 }, (_, index) =>
      graph.deliver({ subject: `Batch ${index}`, at: Date.UTC(2026, 8, 1) }),
    );
    const inbox = createInbox(graph.native);
    await inbox.load();
    await backfilled(inbox);
    expect(progress(inbox)?.downloaded).toBe(120);
    const folders = await downloaded(graph);
    expect(folders.get('INBOX')).toStrictEqual(sorted(ids));
  });

  it('lists a receipt shared by thousands of messages once each, across a relaunch', async () => {
    expect.hasAssertions();
    const graph = createGraph();
    const ids = Array.from({ length: 2601 }, (_, index) =>
      graph.deliver({ subject: `Batch ${index}`, at: Date.UTC(2026, 8, 1) }),
    );
    let refusal: number | undefined = 503;
    const interrupted = createInbox(refusingAfter(graph, 30, () => refusal));
    await interrupted.load();
    await vi.waitFor(() => {
      expect(progress(interrupted)?.paused).toBe(true);
    });
    interrupted.forget();
    refusal = undefined;
    const listedBefore = inboxPages(graph);

    const relaunched = createInbox(graph.native);
    await relaunched.load();
    await backfilled(relaunched);
    expect(progress(relaunched)?.downloaded).toBe(2601);
    // Each step continues where the last page within the shared receipt ended.
    expect(inboxPages(graph) - listedBefore).toBeLessThan(30);
    const folders = await downloaded(graph);
    expect(folders.get('INBOX')).toStrictEqual(sorted(ids));
  });

  it('downloads folders beyond those Move to lists, across a relaunch', async () => {
    expect.hasAssertions();
    const graph = createGraph(100);
    const folders = Array.from({ length: 260 }, (_, index) =>
      graph.createFolder(`Folder ${String(index).padStart(3, '0')}`),
    );
    // Sorted after every other folder, on the last page of the folder list.
    const last = graph.createFolder('Folder 260');
    const nested = graph.createFolder('Nested', folders[150]);
    const lastIds = delivered(graph, 3, last);
    const nestedIds = delivered(graph, 2, nested);
    delivered(graph, 4, 'inbox');
    let refusal: number | undefined = 503;
    const interrupted = createInbox(refusingFolderPages(graph, () => refusal));
    await interrupted.load();
    // Until every folder is found, the download claims no total and is not complete.
    await vi.waitFor(() => {
      expect(progress(interrupted)?.paused).toBe(true);
    });
    expect(progress(interrupted)).not.toHaveProperty('total');
    interrupted.forget();
    refusal = undefined;

    const relaunched = createInbox(graph.native);
    await relaunched.load();
    await backfilled(relaunched);
    expect(progress(relaunched)).toStrictEqual({
      downloaded: 9,
      total: 9,
      complete: true,
    });
    // A folder Move to does not list keeps its history through later synchronizations.
    await relaunched.load();
    const saved = await downloaded(graph);
    expect(saved.get(last)).toStrictEqual(sorted(lastIds));
    expect(saved.get(nested)).toStrictEqual(sorted(nestedIds));
  });

  it('resumes after relaunch without rewinding or listing a page twice', async () => {
    expect.hasAssertions();
    const graph = createGraph();
    const ids = delivered(graph, 300, 'inbox');
    let refusal: number | undefined = 503;
    const interrupted = createInbox(refusingAfter(graph, 4, () => refusal));
    await interrupted.load();
    // The failed read pauses the backfill until the next synchronization. Each later page lists
    // from the oldest receipt before it, so its first message was listed already.
    await vi.waitFor(() => {
      expect(progress(interrupted)).toStrictEqual({
        downloaded: 197,
        total: 300,
        complete: false,
        paused: true,
      });
    });
    interrupted.forget();
    refusal = undefined;
    const earlier = historyListings(graph);

    const relaunched = createInbox(graph.native);
    await relaunched.load();
    await backfilled(relaunched);
    expect(progress(relaunched)).toStrictEqual({
      downloaded: 300,
      total: 300,
      complete: true,
    });
    const resumed = historyListings(graph).slice(earlier.length);
    // The relaunch begins at the failed page; no earlier page is listed again.
    expect(resumed.filter((entry) => earlier.includes(entry))).toStrictEqual(
      [],
    );
    expect(
      historyListings(graph).filter((entry) => entry.startsWith('inbox')),
    ).toHaveLength(7);
    const folders = await downloaded(graph);
    expect(folders.get('INBOX')).toStrictEqual(sorted(ids));
  });

  it('keeps new, moved, deleted and read mail current during and after the pass', async () => {
    expect.hasAssertions();
    const graph = createGraph();
    const projects = graph.createFolder('Projects');
    const ids = delivered(graph, 300, 'inbox');
    const projectIds = delivered(graph, 60, projects);
    let refusal: number | undefined = 503;
    const inbox = createInbox(refusingAfter(graph, 4, () => refusal));
    await inbox.load();
    await vi.waitFor(() => {
      expect(progress(inbox)?.paused).toBe(true);
    });
    // Older mail already listed and mail the pass has yet to list both change.
    const [oldest = '', older = '', old = ''] = ids;
    const [listedMoved = ''] = ids.slice(-1);
    graph.move(listedMoved, projects);
    graph.purge(old);
    graph.markRead(oldest);
    graph.move(older, 'deleteditems');
    const arrival = graph.deliver({ subject: 'Arrival' });
    refusal = undefined;
    await inbox.load();
    await backfilled(inbox);
    const expected = ids.filter(
      (id) => ![listedMoved, old, older].includes(id),
    );
    let folders = await downloaded(graph);
    expect(folders.get('INBOX')).toStrictEqual(sorted([...expected, arrival]));
    expect(folders.get(projects)).toStrictEqual(
      sorted([...projectIds, listedMoved]),
    );

    // Later changes reach the complete history through each folder's delta link.
    graph.move(arrival, projects);
    await inbox.load();
    await vi.waitFor(async () => {
      folders = await downloaded(graph);
      expect(folders.get(projects)).toContain(arrival);
    });
    expect(folders.get('INBOX')).toStrictEqual(sorted(expected));
    expect(progress(inbox)?.complete).toBe(true);
  });

  it('lists a folder again after Graph expires its delta link, keeping the last pass', async () => {
    expect.hasAssertions();
    const graph = createGraph();
    const ids = delivered(graph, 150, 'inbox');
    const inbox = createInbox(graph.native);
    await inbox.load();
    await backfilled(inbox);
    graph.expireDelta();
    const arrival = graph.deliver({ subject: 'After expiry' });
    const shown = shownCounts(inbox);
    await inbox.load();
    await vi.waitFor(async () => {
      const folders = await downloaded(graph);
      expect(folders.get('INBOX')).toStrictEqual(sorted([...ids, arrival]));
    });
    await backfilled(inbox);
    shown.stop();
    // Progress never falls back to the empty new pass.
    expect(Math.min(...shown.counts)).toBeGreaterThanOrEqual(150);
    expect(progress(inbox)?.downloaded).toBe(151);
  });

  it('pauses on throttling and stops for a refused grant, keeping its place', async () => {
    expect.hasAssertions();
    const graph = createGraph();
    delivered(graph, 120, 'inbox');
    let refusal: number | undefined = 429;
    const inbox = createInbox(refusingAfter(graph, 1, () => refusal));
    await inbox.load();
    await vi.waitFor(() => {
      expect(progress(inbox)).toStrictEqual({
        downloaded: 50,
        total: 120,
        complete: false,
        paused: true,
      });
    });

    refusal = 401;
    await inbox.load();
    await vi.waitFor(() => {
      expect(ready(inbox.getSnapshot()).sync).toBe('authentication');
    });
    expect(progress(inbox)?.downloaded).toBe(50);

    refusal = undefined;
    await inbox.load();
    await backfilled(inbox);
    expect(progress(inbox)?.downloaded).toBe(120);
  });

  it('downloads a large folder in bounded pages', async () => {
    expect.hasAssertions();
    const graph = createGraph();
    const ids = delivered(graph, 5000, 'inbox');
    const inbox = createInbox(graph.native);
    await inbox.load();
    await backfilled(inbox);
    expect(progress(inbox)).toStrictEqual({
      downloaded: 5000,
      total: 5000,
      complete: true,
    });
    // 50 messages, then 49 new below each page's oldest receipt.
    expect(
      historyListings(graph).filter((entry) => entry.startsWith('inbox')),
    ).toHaveLength(103);
    const folders = await downloaded(graph);
    expect(folders.get('INBOX')).toStrictEqual(sorted(ids));
  });
});
