import type { GmailInboxState } from '@private-email/mail-core/gmail-inbox';

import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';
import * as Schema from 'effect/Schema';

import { withNativeHistory } from './native-history-store.ts';

type Graph = ReturnType<typeof createSyntheticGraph>;
type Inbox = ReturnType<typeof createGmailInbox>;

const createGraph = () => withNativeHistory(createSyntheticGraph({ pageSize: 50 }));

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

// Delivers `count` messages to `folder`, a minute apart unless `at` gives them one receipt.
const delivered = (
  graph: Graph,
  count: number,
  folder: string,
  at?: number,
) =>
  Array.from({ length: count }, (_, index) =>
    graph.deliver({
      subject: `${folder} ${index}`,
      folder,
      isRead: index % 2 === 1,
      ...(at === undefined ? {} : { at }),
    }),
  );

const savedHistory = Schema.decodeUnknownSync(
  Schema.fromJsonString(
    Schema.Struct({
      graphHistory: Schema.Array(
        Schema.Struct({
          folder: Schema.String,
          history: Schema.Struct({
            current: Schema.Struct({
              segments: Schema.Array(Schema.Struct({ name: Schema.String })),
            }),
            previous: Schema.optionalKey(
              Schema.Struct({
                segments: Schema.Array(Schema.Struct({ name: Schema.String })),
              }),
            ),
            changes: Schema.Array(
              Schema.Struct({
                id: Schema.String,
                message: Schema.optionalKey(Schema.Struct({ id: Schema.String })),
              }),
            ),
          }),
        }),
      ),
    }),
  ),
);
const segmentIds = Schema.decodeUnknownSync(
  Schema.fromJsonString(Schema.Array(Schema.Struct({ id: Schema.String }))),
);

// The message IDs the saved history holds for each folder, from its segments with the recorded
// changes applied, as the native store returns them.
const downloaded = async (graph: Graph) => {
  const scope = await graph.native.openMailbox();
  const { graphHistory } = savedHistory(scope.document ?? '');
  const folders = new Map<string, string[]>();
  for (const { folder, history } of graphHistory) {
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

const sorted = (ids: readonly string[]) => ids.toSorted();

// Graph refuses history listings after the first `pages` while `failing()` says so, as when it is
// unavailable partway through a folder.
const failingAfter = (
  graph: Graph,
  pages: number,
  failing: () => boolean,
): Graph['native'] => {
  let listed = 0;
  return {
    ...graph.native,
    graphRequest: (url, owner) => {
      if (url.includes('$top=50') && failing()) {
        listed += 1;
        if (listed > pages) {
          return Promise.resolve({ status: 503, body: '{}' });
        }
      }
      return graph.native.graphRequest(url, owner);
    },
  };
};

describe('Microsoft Historical Metadata Backfill', () => {
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
    expect(folders.get('INBOX')).toStrictEqual(sorted(inboxIds));
    expect(folders.get('SENT')).toStrictEqual(sorted(sentIds));
    expect(folders.get('ARCHIVE')).toStrictEqual([]);
    expect(folders.get(projects)).toStrictEqual(sorted(projectIds));
    // Deleted Items stays out, as Gmail's Trash does.
    expect([...folders.keys()]).toHaveLength(4);
  });

  it('lists messages sharing one receipt across pages once each', async () => {
    expect.hasAssertions();
    const graph = createGraph();
    const ids = delivered(graph, 120, 'inbox', Date.UTC(2026, 8, 1));
    const inbox = createInbox(graph.native);
    await inbox.load();
    await backfilled(inbox);
    expect(progress(inbox)?.downloaded).toBe(120);
    expect((await downloaded(graph)).get('INBOX')).toStrictEqual(sorted(ids));
  });

  it('resumes after relaunch without rewinding or listing a page twice', async () => {
    expect.hasAssertions();
    const graph = createGraph();
    const ids = delivered(graph, 300, 'inbox');
    let failing = true;
    const interrupted = createInbox(failingAfter(graph, 4, () => failing));
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
    failing = false;
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
    expect((await downloaded(graph)).get('INBOX')).toStrictEqual(sorted(ids));
  });

  it('keeps new, moved, deleted and read mail current during and after the pass', async () => {
    expect.hasAssertions();
    const graph = createGraph();
    const projects = graph.createFolder('Projects');
    const ids = delivered(graph, 300, 'inbox');
    const projectIds = delivered(graph, 60, projects);
    let failing = true;
    const inbox = createInbox(failingAfter(graph, 4, () => failing));
    await inbox.load();
    await vi.waitFor(() => {
      expect(progress(inbox)?.paused).toBe(true);
    });
    // Older mail already listed and mail the pass has yet to list both change.
    const [oldest, older, old] = ids;
    const listedMoved = ids.at(-1) ?? '';
    graph.move(listedMoved, projects);
    graph.purge(old ?? '');
    graph.markRead(oldest ?? '');
    graph.move(older ?? '', 'deleteditems');
    const arrival = graph.deliver({ subject: 'Arrival' });
    failing = false;
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
    const shown: number[] = [];
    const unsubscribe = inbox.subscribe(() => {
      const downloadedNow = progress(inbox)?.downloaded;
      if (downloadedNow !== undefined) {
        shown.push(downloadedNow);
      }
    });
    await inbox.load();
    await vi.waitFor(async () => {
      expect((await downloaded(graph)).get('INBOX')).toStrictEqual(
        sorted([...ids, arrival]),
      );
    });
    await backfilled(inbox);
    unsubscribe();
    // Progress never falls back to the empty new pass.
    expect(Math.min(...shown)).toBeGreaterThanOrEqual(150);
    expect(progress(inbox)?.downloaded).toBe(151);
  });

  it('pauses on throttling and stops for a refused grant, keeping its place', async () => {
    expect.hasAssertions();
    const graph = createGraph();
    delivered(graph, 120, 'inbox');
    let refusal: number | undefined = 429;
    const native: Graph['native'] = {
      ...graph.native,
      graphRequest: (url, owner) =>
        refusal !== undefined &&
        url.includes('$top=50') &&
        url.includes('$filter')
          ? Promise.resolve({ status: refusal, body: '{}' })
          : graph.native.graphRequest(url, owner),
    };
    const inbox = createInbox(native);
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
    expect((await downloaded(graph)).get('INBOX')).toStrictEqual(sorted(ids));
  });
});
