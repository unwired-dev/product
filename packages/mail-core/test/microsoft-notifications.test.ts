import type { GmailInboxState } from '@private-email/mail-core/gmail-inbox';

import { gmailAction } from '@private-email/mail-core/gmail-actions';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

const microsoftInbox = (graph: ReturnType<typeof createSyntheticGraph>) =>
  createGmailInbox(graph.native, { provider: 'microsoft-graph' });

const pair = <A>(values: readonly A[]): readonly [A, A] => {
  const [first, second] = values;
  if (first === undefined || second === undefined) {
    throw new Error('Expected two messages');
  }
  return [first, second];
};

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

describe('new Inbox notifications for Microsoft mail', () => {
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
    // oxlint-disable-next-line vitest/max-expects -- Preserve classification, replay and commit-order assertions in one journey.
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
      at: Date.UTC(2026, 9, 2),
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

  it('reports arrivals named after an archive shortened a full cache, and refills it', async () => {
    expect.hasAssertions();
    const at = (minute: number) => Date.UTC(2026, 9, 1, 9, minute);
    const graph = createSyntheticGraph({ pageSize: 100 });
    const unlisted = graph.deliver({ subject: 'Unlisted', at: at(0) - 1000 });
    for (const index of Array.from(
      { length: cacheLimit + 1 },
      (_, value) => value,
    )) {
      graph.deliver({ subject: `Listed ${index}`, at: at(0) + index * 1000 });
    }
    const arrivals: string[][] = [];
    const inbox = createGmailInbox(graph.native, {
      provider: 'microsoft-graph',
      arrived: (messages) => {
        arrivals.push(messages.map(({ subject }) => subject));
      },
    });
    await inbox.load();
    const [archived] = pair(ready(inbox.getSnapshot()).messages);
    // Named by the same delta round that settles the archive and refills the cache.
    graph.deliver({ subject: 'Arrived after the archive', at: at(30) });
    // A change to a message the full cache never kept is still not new mail.
    graph.restore(unlisted);
    await inbox.organize(archived, gmailAction.archive);
    await inbox.load();
    expect(arrivals).toStrictEqual([['Arrived after the archive']]);
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

  it('keeps pending arrivals out of a refill when the oldest cached message leaves', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ pageSize: 100 });
    const at = (index: number) => Date.UTC(2026, 9, 1) + index * 1000;
    for (let index = 0; index <= cacheLimit; index += 1) {
      graph.deliver({ subject: `Listed ${index}`, at: at(index) });
    }
    const round = splitRound(graph);
    const arrivals: string[][] = [];
    const inbox = createGmailInbox(round.native, {
      provider: 'microsoft-graph',
      arrived: (messages) => {
        arrivals.push(messages.map(({ id }) => id));
      },
    });
    await inbox.load();
    const oldest = ready(inbox.getSnapshot()).messages.at(-1);
    assert.ok(oldest !== undefined);
    graph.remove(oldest.id);
    // Graph creates moved-in mail anew. Its receipt is newer than the committed cache edge.
    const moved = graph.deliver({ subject: 'Moved in', at: at(1.5) });
    round.split([oldest.id], [moved]);
    await inbox.load();
    expect(arrivals).toStrictEqual([[moved]]);
  });

  it('keeps later committed pages when another store finishes the round before a stale page commits', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 1 });
    await microsoftInbox(graph).load();
    const firstArrival = graph.deliver({ subject: 'First arrival' });
    const laterArrival = graph.deliver({ subject: 'Later arrival' });
    const slowRound = splitRound(graph);
    const fastRound = splitRound(graph);
    slowRound.split([firstArrival], [laterArrival]);
    fastRound.split([firstArrival], [laterArrival]);
    const held = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    let paused = false;
    const native = {
      ...slowRound.native,
      graphRequest: async (
        ...args: Parameters<typeof graph.native.graphRequest>
      ) => {
        const reply = await slowRound.native.graphRequest(...args);
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Hold only the stale store's first delta page while the other commits the round.
        if (!paused && args[0].includes('$deltatoken')) {
          paused = true;
          held.resolve(undefined);
          await release.promise;
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
    const slow = createGmailInbox(native, options);
    const fast = createGmailInbox(fastRound.native, options);
    const loading = slow.load();
    await held.promise;
    await fast.load();
    release.resolve(undefined);
    await loading;
    expect(arrivals).toStrictEqual([[firstArrival], [laterArrival]]);
    expect(ready(slow.getSnapshot()).sync).toBe('current');
  });
});
