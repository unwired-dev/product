import { english } from '@private-email/localization';

import type { GmailInboxState, MessageBodyState } from '../src/gmail-inbox.ts';

import { sendingMailboxes } from '../src/drafts.ts';
import { quickActions } from '../src/gmail-actions.ts';
import { createGmailInbox, threadMessages } from '../src/gmail-inbox.ts';
import {
  createGmailSearch,
  createMailboxes,
  inboxMessages,
} from '../src/mailboxes.ts';
import {
  createRegistration,
  defaultProfile,
  mailboxesOf,
  registrationScreen,
} from '../src/registration.ts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '../src/testing/gmail-mailbox.ts';
import { createSyntheticGraph } from '../src/testing/graph-mailbox.ts';
import { createRegistrationScenario } from '../src/testing/registration-scenarios.ts';
import { syntheticMailboxes } from '../src/testing/registration-vault.ts';
import { png } from './remote-content-fixture.ts';

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

const rich = (state: MessageBodyState | undefined) => {
  if (state?.kind !== 'ready' || state.presentation.rich === undefined) {
    throw new Error(`Expected a rich body, received ${state?.kind}`);
  }
  return state.presentation.rich;
};

const microsoftInbox = (graph: ReturnType<typeof createSyntheticGraph>) =>
  createGmailInbox(graph.native, { provider: 'microsoft-graph' });

// The Graph reads by kind: Inbox lists, delta rounds from the start, and delta links.
const interceptGraph = (
  graph: ReturnType<typeof createSyntheticGraph>,
  reply: (url: string) => { status: number; body: string } | undefined,
) => ({
  ...graph.native,
  graphRequest: (
    url: string,
    scope: Parameters<typeof graph.native.graphRequest>[1],
  ) => {
    const intercepted = reply(url);
    return intercepted === undefined
      ? graph.native.graphRequest(url, scope)
      : Promise.resolve(intercepted);
  },
});

const pair = <A>(values: readonly A[]): readonly [A, A] => {
  const [first, second] = values;
  if (first === undefined || second === undefined) {
    throw new Error('Expected two messages');
  }
  return [first, second];
};

const deltaReply = (url: string, value: readonly unknown[] | undefined) =>
  value !== undefined && url.includes('$deltatoken')
    ? {
        status: 200,
        body: JSON.stringify({
          value,
          '@odata.deltaLink':
            "https://graph.microsoft.com/v1.0/me/mailfolders('inbox')/messages/delta?$deltatoken=4",
        }),
      }
    : undefined;

// The newest Inbox messages a Microsoft mailbox keeps on this device.
const cacheLimit = 200;

// Graph whose next delta round, once split, arrives page by page: the first page's IDs, then each
// later page's from a continuation, the last with the round's link. A single page is followed by
// an empty final one.
const splitRound = (graph: ReturnType<typeof createSyntheticGraph>) => {
  const continuation = `https://graph.microsoft.com/v1.0/me/mailfolders('inbox')/messages/delta?$skiptoken=rest`;
  let pages: ReadonlyArray<readonly string[]> = [];
  let later: ReadonlyArray<readonly string[]> = [];
  let link: string | undefined = undefined;
  const page = (ids: readonly string[], last: boolean) => ({
    status: 200,
    body: JSON.stringify({
      value: ids.map((id) => ({ id })),
      ...(last
        ? { '@odata.deltaLink': link }
        : { '@odata.nextLink': continuation }),
    }),
  });
  return {
    split: (...ids: ReadonlyArray<readonly string[]>) => {
      pages = ids;
    },
    native: {
      ...graph.native,
      graphRequest: async (
        url: string,
        scope: Parameters<typeof graph.native.graphRequest>[1],
      ) => {
        if (later.length > 0 && url === continuation) {
          const [next = [], ...remaining] = later;
          later = remaining;
          return page(next, remaining.length === 0);
        }
        const reply = await graph.native.graphRequest(url, scope);
        if (pages.length === 0 || !url.includes('$deltatoken')) {
          return reply;
        }
        const [first = [], ...rest] = pages;
        pages = [];
        later = rest.length === 0 ? [[]] : rest;
        link = /"@odata\.deltaLink":"(?<link>[^"]+)"/u.exec(reply.body)?.groups
          ?.link;
        return page(first, false);
      },
    },
  };
};

const unavailableMetadata = (url: string, status: number) =>
  /\/attachments(?:\?|$)/u.test(url) ? { status, body: '{}' } : undefined;

const metadataSync = (status: number) =>
  status === 401 ? 'authentication' : 'current';

const unavailableImage = (url: string) =>
  url.includes('/attachments/') ? { status: 503, body: '{}' } : undefined;

// Message reads in order; the folders organizing lists with each synchronization are left out.
const messageReads = (graph: ReturnType<typeof createSyntheticGraph>) =>
  graph.requests.filter(
    (url) => !/\/mailfolders(?:\/[^/]+)?$/u.test(url.pathname.toLowerCase()),
  );
const reads = (graph: ReturnType<typeof createSyntheticGraph>) =>
  messageReads(graph).map((url) => {
    if (url.pathname.toLowerCase().endsWith('/mailfolders/inbox/messages')) {
      return 'list';
    }
    if (url.searchParams.has('$deltatoken')) {
      return 'changes';
    }
    return url.pathname.includes('/delta') ? 'delta' : 'message';
  });

const repeatingDelta = (
  graph: ReturnType<typeof createSyntheticGraph>,
  state: { pages: number; repeated: boolean; requested: string[] },
  link: string,
) =>
  interceptGraph(graph, (url) => {
    if (!url.includes('/delta')) {
      return undefined;
    }
    state.requested.push(url);
    if (!state.repeated) {
      return {
        status: 200,
        body: JSON.stringify({
          value: [],
          '@odata.deltaLink': link.replace(
            '$skiptoken=repeated',
            '$deltatoken=done',
          ),
        }),
      };
    }
    state.pages += 1;
    // A final refusal makes the unfenced implementation settle rather than hang this regression.
    return state.pages > 200
      ? { status: 503, body: '{}' }
      : {
          status: 200,
          body: JSON.stringify({ value: [], '@odata.nextLink': link }),
        };
  });

describe('reading Microsoft mail through Graph', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one synchronization path end to end. */
  it('keeps messages without a conversation identity separate and orders shared conversations after relaunch', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 4 });
    const native = {
      ...graph.native,
      graphRequest: async (
        url: string,
        scope: Parameters<typeof graph.native.graphRequest>[1],
      ) => {
        const reply = await graph.native.graphRequest(url, scope);
        return {
          ...reply,
          body: reply.body
            .replaceAll(
              '"conversationId":"conversation-1"',
              '"conversationId":""',
            )
            .replaceAll(
              '"conversationId":"conversation-2"',
              '"conversationId":""',
            )
            .replaceAll(
              '"conversationId":"conversation-4"',
              '"conversationId":"conversation-3"',
            ),
        };
      },
    };
    const inbox = createGmailInbox(native, { provider: 'microsoft-graph' });
    await inbox.load();
    const state = ready(inbox.getSnapshot());
    const [newest, earlier] = pair(state.messages);
    expect(threadMessages(state, newest.id).map(({ id }) => id)).toStrictEqual([
      newest.id,
      earlier.id,
    ]);
    for (const message of state.messages.slice(2)) {
      expect(threadMessages(state, message.id)).toStrictEqual([message]);
    }
    // An older cache may already contain blank identities; offline reopening must isolate them too.
    const reopened = createGmailInbox(
      {
        ...native,
        openMailbox: async () => {
          const cached = await native.openMailbox();
          return {
            ...cached,
            availability: 'retry',
            document: cached.document?.replaceAll(
              /"threadId":"AAMk[^"]+"/gu,
              '"threadId":""',
            ),
          };
        },
      },
      { provider: 'microsoft-graph' },
    );
    await reopened.load();
    expect(threadMessages(reopened.getSnapshot(), newest.id)).toStrictEqual(
      threadMessages(state, newest.id),
    );
    for (const message of ready(reopened.getSnapshot()).messages.slice(2)) {
      expect(threadMessages(reopened.getSnapshot(), message.id)).toStrictEqual([
        message,
      ]);
    }
  });

  it('bounds repeated delta continuation pages and resumes the saved checkpoint on retry', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 1 });
    const link =
      'https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$skiptoken=repeated';
    const requested: string[] = [];
    const state = { pages: 0, repeated: true, requested };
    const native = repeatingDelta(graph, state, link);
    const inbox = createGmailInbox(native, { provider: 'microsoft-graph' });
    await inbox.load();
    expect(state.pages).toBeLessThanOrEqual(200);
    expect(ready(inbox.getSnapshot())).toMatchObject({
      sync: 'retry',
      messages: [{ subject: 'Synthetic message 0' }],
    });
    expect(graph.commits.at(-1)).toContain(link);
    const completed = state.requested.length;
    state.repeated = false;
    const resumed = createGmailInbox(native, { provider: 'microsoft-graph' });
    await resumed.load();
    expect(state.requested[completed]).toBe(link);
    expect(ready(resumed.getSnapshot())).toMatchObject({
      sync: 'current',
      messages: [{ subject: 'Synthetic message 0' }],
    });
  });

  it('lists the Inbox, completes its delta round and applies later changes after relaunch', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 4, pageSize: 2 });
    const latest = graph.deliver({
      from: { name: 'Maya Chen', address: 'maya@example.invalid' },
      subject: 'Studio review',
      preview: 'Bring your notes',
    });
    const inbox = microsoftInbox(graph);
    await inbox.load();

    const synced = ready(inbox.getSnapshot());
    expect(synced).toMatchObject({
      address: 'casey@example.invalid',
      sync: 'current',
    });
    expect(synced.messages).toHaveLength(5);
    expect(synced.messages[0]).toStrictEqual({
      id: latest,
      threadId: 'conversation-5',
      sender: 'Maya Chen',
      address: 'maya@example.invalid',
      subject: 'Studio review',
      preview: 'Bring your notes',
      receivedAt: expect.stringMatching(/^2026-09-01T\d\d:\d\d:00\.000Z$/u),
      unread: true,
      labels: ['INBOX', 'UNREAD'],
    });
    // Microsoft mail offers Graph's actions, without Gmail's star.
    expect(
      synced.messages
        .slice(0, 1)
        .flatMap((message) =>
          quickActions(english, message, { provider: 'microsoft-graph' }),
        )
        .map(({ name }) => name),
    ).toStrictEqual(['read', 'archive', 'trash', 'spam']);
    // The Inbox shows after one list; the delta round walks every page, then the Inbox is
    // listed again so nothing changed during the round is missed, and the round's link finds
    // nothing newer.
    expect(reads(graph)).toStrictEqual([
      'list',
      'list',
      'list',
      'delta',
      'delta',
      'delta',
      'list',
      'list',
      'list',
      'changes',
    ]);
    expect(graph.commits.at(-1)).toContain('"kind":"graph-current"');

    const arrived = graph.deliver({ subject: 'New arrival' });
    const [, read = '', removed = ''] = synced.messages.map(({ id }) => id);
    graph.markRead(read);
    graph.remove(removed);
    graph.requests.length = 0;

    const relaunched = microsoftInbox(graph);
    await relaunched.load();
    const updated = ready(relaunched.getSnapshot());
    // One delta page carries every change; its new link then finds nothing newer.
    expect(reads(graph)).toStrictEqual([
      'changes',
      'message',
      'message',
      'message',
      'changes',
    ]);
    expect(updated.messages.map(({ id }) => id)).toContain(arrived);
    expect(updated.messages.map(({ id }) => id)).not.toContain(removed);
    expect(updated.messages.find(({ id }) => id === read)?.unread).toBe(false);
    expect(updated.messages).toHaveLength(5);

    // An unchanged Inbox returning the same link commits nothing.
    const commits = graph.commits.length;
    await relaunched.load();
    expect(graph.commits).toHaveLength(commits);
    expect(ready(relaunched.getSnapshot()).sync).toBe('current');

    // A fresh link from an empty round is saved, once per synchronization, and used next time.
    graph.rotateDelta();
    graph.requests.length = 0;
    await relaunched.load();
    expect(reads(graph)).toStrictEqual(['changes']);
    expect(graph.commits).toHaveLength(commits + 1);
    expect(graph.commits.at(-1)).toContain('$deltatoken=');
    expect(graph.commits.at(-1)).toContain('r1');
    await relaunched.load();
    expect(reads(graph)).toStrictEqual(['changes', 'changes']);
    expect(messageReads(graph).at(-1)?.searchParams.get('$deltatoken')).toMatch(
      /r1$/u,
    );
    expect(graph.commits).toHaveLength(commits + 2);
    expect(ready(relaunched.getSnapshot()).sync).toBe('current');
  });

  it('reports only unread mail newly arriving in the Inbox, once each, after its delta page commits', async () => {
    expect.hasAssertions();
    const at = (hour: number, minute = 0) => Date.UTC(2026, 9, 1, hour, minute);
    const graph = createSyntheticGraph({ messages: 3 });
    // In the Inbox only after the first synchronization.
    const movedIn = graph.deliver({ subject: 'Moved in', at: at(9, 10) });
    graph.remove(movedIn);
    const round = splitRound(graph);
    const arrivals: string[][] = [];
    const committed: boolean[] = [];
    const inbox = createGmailInbox(round.native, {
      provider: 'microsoft-graph',
      arrived: (messages) => {
        committed.push(
          messages.every(({ id }) => graph.commits.at(-1)?.includes(id)),
        );
        arrivals.push(messages.map(({ subject }) => subject));
      },
    });
    // The first listing and its delta round are historical.
    await inbox.load();
    expect(arrivals).toStrictEqual([]);

    const [updated = ''] = ready(inbox.getSnapshot())
      .messages.filter(({ unread }) => unread)
      .map(({ id }) => id);
    const older = graph.deliver({ subject: 'Older arrival', at: at(10) });
    const newer = graph.deliver({ subject: 'New arrival', at: at(10, 10) });
    const read = graph.deliver({
      subject: 'Read elsewhere',
      at: at(10, 5),
      isRead: true,
    });
    // Graph creates a moved message anew in the Inbox, so it is new mail; a change to a listed
    // message is not.
    graph.restore(movedIn);
    graph.restore(updated);
    // Newer mail on the round's first page does not hide older new mail on its second.
    round.split([newer], [older, read, movedIn, updated]);
    await inbox.load();
    expect(arrivals).toStrictEqual([
      ['New arrival'],
      ['Older arrival', 'Moved in'],
    ]);
    // Synchronizing again reports nothing twice.
    await inbox.load();
    expect(arrivals).toHaveLength(2);

    // Mail found by listing again after Graph expired the delta link is not reported.
    graph.expireDelta();
    graph.deliver({
      subject: 'Arrived while the link expired',
      at: at(10, 40),
    });
    await inbox.load();
    expect(arrivals).toHaveLength(2);
    graph.deliver({ subject: 'Later arrival', at: at(11, 10) });
    await inbox.load();
    expect(arrivals).toStrictEqual([
      ['New arrival'],
      ['Older arrival', 'Moved in'],
      ['Later arrival'],
    ]);
    expect(committed).toStrictEqual([true, true, true]);
  });

  it('resumes an interrupted delta round and reports later deliveries after relaunch', async () => {
    expect.hasAssertions();
    const at = (hour: number) => Date.UTC(2026, 9, 1, hour);
    vi.useFakeTimers({ now: at(9), toFake: ['Date'] });
    try {
      const graph = createSyntheticGraph();
      const round = splitRound(graph);
      let interrupted = false;
      const native = {
        ...round.native,
        graphRequest: (
          url: string,
          scope: Parameters<typeof graph.native.graphRequest>[1],
        ) => {
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Interrupt only the round's first continuation, before the provider answers.
          if (!interrupted && url.includes('$skiptoken=rest')) {
            interrupted = true;
            return Promise.reject(
              Object.assign(new Error('Synthetic interruption'), {
                code: 'unavailable',
              }),
            );
          }
          return round.native.graphRequest(url, scope);
        },
      };
      const arrivals: string[][] = [];
      const options = {
        provider: 'microsoft-graph' as const,
        arrived: (messages: ReadonlyArray<{ readonly subject: string }>) => {
          arrivals.push(messages.map(({ subject }) => subject));
        },
      };
      const inbox = createGmailInbox(native, options);
      await inbox.load();
      vi.setSystemTime(at(10));
      round.split([
        graph.deliver({ subject: 'Before interruption', at: at(10) }),
      ]);
      await inbox.load();
      expect(arrivals).toStrictEqual([['Before interruption']]);

      graph.deliver({ subject: 'During interruption', at: at(11) });
      vi.setSystemTime(at(12));
      const relaunched = createGmailInbox(native, options);
      await relaunched.load();
      // The old round's empty final page ends that synchronization; the next one reads later mail.
      await relaunched.load();
      expect(arrivals).toStrictEqual([
        ['Before interruption'],
        ['During interruption'],
      ]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('reports no message a full cache dropped, whether Graph changes it or names it again later in a round', async () => {
    expect.hasAssertions();
    const at = (minute: number) => Date.UTC(2026, 9, 1, 9, minute);
    vi.useFakeTimers({ now: at(30), toFake: ['Date'] });
    try {
      const graph = createSyntheticGraph({ pageSize: 100 });
      // The oldest historical message does not fit the cache.
      const listed = Array.from({ length: cacheLimit + 1 }, (_, index) =>
        graph.deliver({
          subject: `Listed ${index}`,
          at: at(26) + index * 1000,
        }),
      );
      const round = splitRound(graph);
      const arrivals: string[][] = [];
      const inbox = createGmailInbox(round.native, {
        provider: 'microsoft-graph',
        arrived: (messages) => {
          arrivals.push(messages.map(({ subject }) => subject));
        },
      });
      await inbox.load();
      // A change to the dropped message is not new mail.
      const [dropped = ''] = listed;
      graph.restore(dropped);
      await inbox.load();
      expect(arrivals).toStrictEqual([]);

      // One arrival, then enough newer ones to drop it from the cache, then Graph names it again.
      vi.setSystemTime(at(40));
      const first = graph.deliver({ subject: 'First arrival', at: at(31) });
      const newer = Array.from({ length: cacheLimit }, (_, index) =>
        graph.deliver({ subject: `Newer ${index}`, at: at(32) + index * 1000 }),
      );
      round.split([first], newer, [first]);
      await inbox.load();
      expect(arrivals.flat()).toHaveLength(cacheLimit + 1);
      expect(
        arrivals.flat().filter((subject) => subject === 'First arrival'),
      ).toHaveLength(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it('reports an arrival a refill listed when its later delta page resumes after relaunch', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: cacheLimit });
    const round = splitRound(graph);
    const arrivals: string[][] = [];
    let interrupted = false;
    const native = {
      ...round.native,
      graphRequest: (
        url: string,
        scope: Parameters<typeof graph.native.graphRequest>[1],
      ) => {
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Interrupt after the refill commits, before the next delta page.
        if (!interrupted && url.includes('$skiptoken=rest')) {
          interrupted = true;
          return Promise.reject(
            Object.assign(new Error('Synthetic interruption'), {
              code: 'unavailable',
            }),
          );
        }
        return round.native.graphRequest(url, scope);
      },
    };
    const options = {
      provider: 'microsoft-graph' as const,
      arrived: (messages: ReadonlyArray<{ readonly id: string }>): void => {
        arrivals.push(messages.map(({ id }) => id));
      },
    };
    const inbox = createGmailInbox(native, options);
    await inbox.load();
    const [firstMessage] = pair(ready(inbox.getSnapshot()).messages);
    const removed = firstMessage.id;
    graph.remove(removed);
    const delivered = graph.deliver({
      subject: 'After the refill',
      at: Date.now(),
    });
    round.split([removed], [delivered]);
    await inbox.load();
    // The refill keeps the arrival for its own delta page.
    expect(
      ready(inbox.getSnapshot()).messages.some(({ id }) => id === delivered),
    ).toBe(false);
    expect(arrivals).toStrictEqual([]);
    const relaunched = createGmailInbox(native, options);
    await relaunched.load();
    await relaunched.load();
    expect(arrivals).toStrictEqual([[delivered]]);
  });

  it('refills older mail without letting pending arrivals disable the evicted-message guard', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ pageSize: 100 });
    const historical = Array.from({ length: cacheLimit + 2 }, (_, index) =>
      graph.deliver({
        subject: `Historical ${index}`,
        at: Date.UTC(2026, 9, 1) + index * 1000,
      }),
    );
    const round = splitRound(graph);
    const arrivals: string[][] = [];
    const inbox = createGmailInbox(round.native, {
      provider: 'microsoft-graph',
      arrived: (messages) => {
        arrivals.push(messages.map(({ id }) => id));
      },
    });
    await inbox.load();
    const removed = ready(inbox.getSnapshot()).messages.slice(0, 2);
    for (const { id } of removed) {
      graph.remove(id);
    }
    const delivered = graph.deliver({
      subject: 'Actual arrival',
      at: Date.UTC(2026, 9, 2),
    });
    const [dropped] = pair(historical);
    graph.restore(dropped);
    round.split(
      removed.map(({ id }) => id),
      [dropped, delivered],
    );
    await inbox.load();
    expect(arrivals).toStrictEqual([[delivered]]);
    expect(ready(inbox.getSnapshot()).messages).toHaveLength(cacheLimit);
  });

  it('reports one arrival once when two stores read its delta page before either commits', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 1 });
    await microsoftInbox(graph).load();
    const delivered = graph.deliver({ subject: 'One arrival', at: Date.now() });
    const gate = Promise.withResolvers<undefined>();
    let reads = 0;
    const native = {
      ...graph.native,
      graphRequest: async (
        ...args: Parameters<typeof graph.native.graphRequest>
      ) => {
        const reply = await graph.native.graphRequest(...args);
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Hold only the first delta read from each store.
        if (args[0].includes('$deltatoken') && reads < 2) {
          reads += 1;
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Release after both stores captured the same provider page.
          if (reads === 2) {
            gate.resolve(undefined);
          }
          await gate.promise;
        }
        return reply;
      },
    };
    const arrivals: string[][] = [];
    const options = {
      provider: 'microsoft-graph' as const,
      arrived: (messages: ReadonlyArray<{ readonly id: string }>) => {
        arrivals.push(messages.map(({ id }) => id));
      },
    };
    const first = createGmailInbox(native, options);
    const second = createGmailInbox(native, options);
    await Promise.all([first.load(), second.load()]);
    expect(arrivals).toStrictEqual([[delivered]]);
    expect([
      ready(first.getSnapshot()).sync,
      ready(second.getSnapshot()).sync,
    ]).toStrictEqual(['current', 'current']);
  });

  it('lists again when Graph expires the delta link, showing saved mail meanwhile', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 3, pageSize: 2 });
    const inbox = microsoftInbox(graph);
    await inbox.load();
    const saved = ready(inbox.getSnapshot()).messages;
    graph.expireDelta();
    const arrived = graph.deliver({ subject: 'After expiry' });
    graph.requests.length = 0;
    const published: GmailInboxState[] = [];
    inbox.subscribe(() => {
      published.push(inbox.getSnapshot());
    });

    await inbox.load();
    expect(reads(graph)).toStrictEqual([
      'changes',
      'list',
      'list',
      'delta',
      'delta',
      'list',
      'list',
      'changes',
    ]);
    expect(published[0]).toMatchObject({ messages: saved, sync: 'syncing' });
    const relisted = ready(inbox.getSnapshot());
    expect(relisted.sync).toBe('current');
    expect(relisted.messages.map(({ id }) => id)).toStrictEqual([
      arrived,
      ...saved.map(({ id }) => id),
    ]);
  });

  it('fills a full cache again from Graph when a cached message leaves the Inbox', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 201, pageSize: 100 });
    const inbox = microsoftInbox(graph);
    await inbox.load();
    const listed = ready(inbox.getSnapshot()).messages;
    expect(listed).toHaveLength(200);
    const [{ id: first } = { id: '' }] = listed;
    graph.remove(first);
    graph.requests.length = 0;

    await inbox.load();
    const refilled = ready(inbox.getSnapshot()).messages;
    expect(reads(graph)).toStrictEqual([
      'changes',
      'message',
      'list',
      'changes',
    ]);
    expect(refilled).toHaveLength(200);
    expect(refilled.map(({ id }) => id)).not.toContain(first);
    // The oldest Inbox message, beyond the cache before, now fits.
    expect(refilled.at(-1)?.subject).toBe('Synthetic message 0');
  });

  it('reconciles partial and repeated delta identities against their current Inbox state', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 2 });
    let delta: readonly unknown[] | undefined = undefined;
    const inbox = createGmailInbox(
      interceptGraph(graph, (url) => {
        const reply = deltaReply(url, delta);
        delta = undefined;
        return reply;
      }),
      { provider: 'microsoft-graph' },
    );
    await inbox.load();
    const [read, removed] = pair(ready(inbox.getSnapshot()).messages);
    graph.markRead(read.id);
    graph.remove(removed.id);
    delta = [
      { id: read.id, isRead: true },
      {
        id: removed.id,
        receivedDateTime: removed.receivedAt,
        subject: 'Stale change',
      },
      { id: removed.id, '@removed': { reason: 'deleted' } },
    ];
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({ sync: 'current' });
    expect(ready(inbox.getSnapshot()).messages).toStrictEqual([
      { ...read, unread: false },
    ]);
  });

  it('reads an HTML body with its inline image, answers it, and downloads an attachment by its own size', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph();
    const logo = [...Buffer.from(png(40, 30), 'base64')];
    const notes = [...Buffer.from('Notes here.\n')];
    const id = graph.deliver({
      subject: 'Plans',
      body: {
        contentType: 'html',
        content: '<p>Garden plans ✿</p><img src="cid:logo@example" alt="Logo">',
      },
      attachments: [
        {
          name: 'logo.png',
          contentType: 'image/png',
          bytes: logo,
          isInline: true,
          contentId: 'logo@example',
        },
        { name: 'notes.txt', contentType: 'text/plain', bytes: notes },
      ],
      headers: [{ name: 'References', value: '<earlier@example.invalid>' }],
    });
    const inbox = microsoftInbox(graph);
    await inbox.load();
    const close = inbox.retainMessage(id);
    await inbox.readMessage(id);

    const body = rich(inbox.messageBody(id));
    expect(body.document).toContain('Garden plans ✿');
    expect(body.document).toContain('src="data:image/png;base64,');
    // The inline image is not offered as a file; Graph's approximate size is shown until download.
    expect(inbox.messageAttachments(id)).toStrictEqual([
      {
        locator: '0.1',
        name: 'notes.txt',
        mimeType: 'text/plain',
        size: notes.length + 120,
        state: { kind: 'available' },
      },
    ]);
    expect(inbox.responseSource(id)?.headers).toStrictEqual({
      from: '"Rowan Hale" <rowan@example.invalid>',
      to: '"Casey" <casey@example.invalid>',
      messageId: `<${id}@example.invalid>`,
      references: '<earlier@example.invalid>',
    });

    await inbox.downloadAttachment(id, '0.1');
    expect(inbox.messageAttachments(id)?.[0]?.state).toStrictEqual({
      kind: 'downloaded',
    });
    expect([...graph.savedFiles.values()]).toStrictEqual([
      { name: 'notes.txt', bytes: Uint8Array.from(notes) },
    ]);
    close();
  });

  it('pages attachment metadata and downloads only visible inline references', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ pageSize: 1 });
    const image = [...Buffer.from(png(40, 30), 'base64')];
    const id = graph.deliver({
      body: {
        contentType: 'html',
        content:
          '<p>Visible</p><img hidden src="cid:hidden"><img src="cid:shown">',
      },
      attachments: [
        {
          name: 'hidden.png',
          contentType: 'image/png',
          bytes: image,
          isInline: true,
          contentId: 'hidden',
        },
        {
          name: 'unused.png',
          contentType: 'image/png',
          bytes: image,
          isInline: true,
          contentId: 'unused',
        },
        {
          name: 'shown.png',
          contentType: 'image/png',
          bytes: image,
          isInline: true,
          contentId: 'shown',
        },
        { name: 'notes.txt', contentType: 'text/plain', bytes: [65] },
      ],
    });
    const inbox = microsoftInbox(graph);
    await inbox.load();
    const close = inbox.retainMessage(id);
    await inbox.readMessage(id);
    expect(rich(inbox.messageBody(id)).document).toContain(
      'data:image/png;base64,',
    );
    expect(
      graph.requests
        .filter((url) => /\/attachments\//u.test(url.pathname))
        .map((url) => url.pathname),
    ).toStrictEqual([`/v1.0/me/messages/${id}/attachments/${id}-attachment-2`]);
    expect(inbox.messageAttachments(id)?.map(({ name }) => name)).toStrictEqual(
      ['notes.txt'],
    );
    close();
  });

  it('keeps readable body text when an optional inline image is temporarily unavailable', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph();
    const id = graph.deliver({
      body: {
        contentType: 'html',
        content: '<p>Important text</p><img src="cid:logo">',
      },
      attachments: [
        {
          name: 'logo.png',
          contentType: 'image/png',
          bytes: [...Buffer.from(png(40, 30), 'base64')],
          isInline: true,
          contentId: 'logo',
        },
      ],
    });
    const inbox = createGmailInbox(interceptGraph(graph, unavailableImage), {
      provider: 'microsoft-graph',
    });
    await inbox.load();
    const close = inbox.retainMessage(id);
    await inbox.readMessage(id);
    expect(rich(inbox.messageBody(id)).document).toContain('Important text');
    expect(rich(inbox.messageBody(id)).document).not.toContain(
      'data:image/png;base64,',
    );
    close();
  });

  it.each([503, 401])(
    'keeps text and retries attachment metadata after Graph responds %s',
    async (status) => {
      expect.hasAssertions();
      vi.useFakeTimers({ now: Date.UTC(2026, 8, 1, 1), toFake: ['Date'] });
      try {
        const graph = createSyntheticGraph();
        const id = graph.deliver({
          body: {
            contentType: 'text',
            content: 'Readable despite metadata failure',
          },
          attachments: [
            { name: 'notes.txt', contentType: 'text/plain', bytes: [65] },
          ],
        });
        const inbox = createGmailInbox(
          interceptGraph(graph, (url) => unavailableMetadata(url, status)),
          { provider: 'microsoft-graph' },
        );
        await inbox.load();
        const close = inbox.retainMessage(id);
        await inbox.readMessage(id);
        expect(inbox.messageBody(id)).toMatchObject({
          kind: 'ready',
          presentation: {
            readable: {
              paragraphs: [[{ text: 'Readable despite metadata failure' }]],
            },
          },
        });
        expect(ready(inbox.getSnapshot()).sync).toBe(metadataSync(status));
        close();
        inbox.forget();

        const relaunched = microsoftInbox(graph);
        await relaunched.load();
        const release = relaunched.retainMessage(id);
        await relaunched.readMessage(id);
        expect(relaunched.messageBody(id)).toMatchObject({
          kind: 'ready',
          presentation: {
            readable: {
              paragraphs: [[{ text: 'Readable despite metadata failure' }]],
            },
          },
        });
        expect(relaunched.messageAttachments(id)).toMatchObject([
          { name: 'notes.txt' },
        ]);
        release();
        relaunched.forget();
      } finally {
        vi.useRealTimers();
      }
    },
  );

  it.each([
    { status: 200, reason: 'failed', reply: () => undefined },
    {
      status: 401,
      reason: 'authentication',
      reply: (url: string) => unavailableMetadata(url, 401),
    },
    {
      status: 503,
      reason: 'failed',
      reply: (url: string) => unavailableMetadata(url, 503),
    },
  ])(
    'rejects oversized Graph metadata and preserves an attachment grant refusal ($status)',
    async ({ status, reason, reply }) => {
      expect.hasAssertions();
      const graph = createSyntheticGraph();
      const id = graph.deliver({
        body: { contentType: 'text', content: 'Over metadata budget' },
        headers: [{ name: 'References', value: 'x'.repeat(256 * 1024 + 1) }],
        attachments: [
          { name: 'notes.txt', contentType: 'text/plain', bytes: [65] },
        ],
      });
      const inbox = createGmailInbox(interceptGraph(graph, reply), {
        provider: 'microsoft-graph',
      });
      await inbox.load();
      const close = inbox.retainMessage(id);
      await inbox.readMessage(id);
      expect(inbox.messageBody(id)).toStrictEqual({
        kind: 'unavailable',
        reason,
      });
      expect(ready(inbox.getSnapshot()).sync).toBe(metadataSync(status));
      expect(graph.cachedBodies().has(id)).toBe(false);
      close();
      inbox.forget();
    },
  );

  it('asks for Microsoft authorization again when Graph refuses the grant', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 2 });
    const inbox = microsoftInbox(graph);
    await inbox.load();
    graph.fail({ status: 401 });
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({
      sync: 'authentication',
      messages: expect.any(Array),
    });
    expect(ready(inbox.getSnapshot()).messages).toHaveLength(2);
  });

  it('reports a refused Microsoft grant of the only connection as Microsoft mail being unavailable', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const registration = createRegistration(synthetic.vault);
    await registration.register('apple');
    await registration.addMailbox('microsoft-graph');
    synthetic.expire('casey@example.invalid');
    await registration.restore();
    expect(registration.getSnapshot().snapshot).toMatchObject({
      kind: 'mailbox-needed',
      reason: 'microsoft-unavailable',
    });
  });

  it.each([
    {
      graphProfile: defaultProfile,
      subjects: ['From Outlook', 'From Gmail'],
      // Online search covers each profile's own mailboxes, Microsoft ones included.
      found: { default: ['microsoft-graph', 'gmail'], work: [] },
    },
    {
      graphProfile: 'work',
      subjects: ['From Gmail'],
      found: { default: ['gmail'], work: ['microsoft-graph'] },
    },
  ])(
    'reads, searches and sends Microsoft mail in $graphProfile beside Gmail',
    async ({ graphProfile, subjects, found }) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail({ address: 'other@example.invalid' });
      const graph = createSyntheticGraph();
      gmail.deliver({ subject: 'From Gmail', at: Date.UTC(2026, 8, 1, 9) });
      graph.deliver({ subject: 'From Outlook', at: Date.UTC(2026, 8, 1, 10) });
      const synthetic = await createRegistrationScenario(
        'registration-success',
      );
      const registration = createRegistration(synthetic.vault);
      await registration.register('apple');
      // Microsoft mail can be the first mailbox, without any Gmail grant.
      await registration.addMailbox('microsoft-graph');
      expect(mailboxesOf(registration.getSnapshot().snapshot)).toStrictEqual([
        {
          id: syntheticMailboxes['casey@example.invalid'],
          provider: 'microsoft-graph',
          address: 'casey@example.invalid',
          epoch: 'synthetic-epoch-1',
          state: 'connected',
          profile: defaultProfile,
        },
      ]);
      expect(
        registrationScreen(english, registration.getSnapshot(), undefined).copy
          .title,
      ).toBe('Mail connected');
      await registration.addMailbox('gmail', true);
      const mailboxes = createMailboxes(
        syntheticConnections({
          [syntheticMailboxes['other@example.invalid']]: gmail,
          [syntheticMailboxes['casey@example.invalid']]: graph,
        }),
        {
          ...registration,
          getSnapshot: () => {
            const current = registration.getSnapshot();
            const profiles = {
              gmail: defaultProfile,
              'microsoft-graph': graphProfile,
              imap: defaultProfile,
            };
            return {
              ...current,
              snapshot: {
                ...current.snapshot,
                mailboxes: JSON.stringify(
                  mailboxesOf(current.snapshot).map((connection) => ({
                    ...connection,
                    profile: profiles[connection.provider],
                  })),
                ),
              },
            };
          },
        },
      );
      await mailboxes.load();

      const shown = mailboxes.getSnapshot();
      expect(
        shown.map(({ provider, address }) => [provider, address]),
      ).toStrictEqual([
        ['microsoft-graph', 'casey@example.invalid'],
        ['gmail', 'other@example.invalid'],
      ]);
      expect(
        inboxMessages(shown, { profile: defaultProfile }).map(
          ({ message }) => message.subject,
        ),
      ).toStrictEqual(subjects);
      expect(
        inboxMessages(shown, {
          profile: graphProfile,
          mailbox: syntheticMailboxes['casey@example.invalid'],
        }).map(({ message }) => message.subject),
      ).toStrictEqual(['From Outlook']);
      expect(inboxMessages(shown, { profile: 'unknown' })).toStrictEqual([]);
      const providers = async (profile: string) => {
        const search = createGmailSearch(shown, 'From', { profile });
        await search.search();
        const result = search.getSnapshot().found;
        return {
          available: search.available,
          failures: result?.failures,
          found: result?.results.map(({ mailbox }) => mailbox.provider),
        };
      };
      await expect(providers('work')).resolves.toStrictEqual({
        available: found.work.length > 0,
        failures: [],
        found: found.work,
      });
      await expect(providers(defaultProfile)).resolves.toStrictEqual({
        available: true,
        failures: [],
        found: found.default,
      });
      // Graph searches every folder, once, for the quoted query.
      expect(graph.searches).toStrictEqual(['"From"']);

      expect(
        sendingMailboxes(
          mailboxesOf(registration.getSnapshot().snapshot),
          defaultProfile,
        ).map(({ address }) => address),
      ).toStrictEqual(['casey@example.invalid', 'other@example.invalid']);
    },
  );
});
