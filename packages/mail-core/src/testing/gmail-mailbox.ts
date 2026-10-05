import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';

import type { NativeGmailMailbox } from '../gmail-inbox.ts';

// A controlled Gmail API and native mailbox cache for tests. It answers the Gmail reads the
// Inbox makes with Gmail's response shapes and keeps the cache's revision and address rules.
interface SyntheticMessage {
  readonly id: string;
  readonly from: string;
  readonly subject: string;
  readonly snippet: string;
  readonly internalDate: number;
  readonly labels: Set<string>;
}

type HistoryKind =
  | 'messagesAdded'
  | 'messagesDeleted'
  | 'labelsAdded'
  | 'labelsRemoved';

type Failure =
  | { readonly status: number; readonly body?: string }
  | { readonly code: string };

const respond = (body: unknown) =>
  Promise.resolve({ status: 200, body: JSON.stringify(body) });

const rejection = (code: string) =>
  Promise.reject(Object.assign(new Error('Synthetic failure'), { code }));

export function createSyntheticGmail({
  address: initialAddress = 'alex@example.invalid',
  messages: count = 0,
}: { readonly address?: string; readonly messages?: number } = {}) {
  let address = initialAddress;
  let historyId = 1000;
  let nextId = 0x1_00;
  let expiredBefore = 0;
  const messages = new Map<string, SyntheticMessage>();
  const history: Array<{ id: number; kind: HistoryKind; message: string }> = [];
  const failures: Failure[] = [];
  // One-shot failures for a matching list page, after the pages before it succeeded.
  const pageFailures = new Map<string, Failure>();
  const openFailures: string[] = [];
  const commitFailures: string[] = [];
  const requests: Array<{ path: string; query: URLSearchParams }> = [];
  const commits: string[] = [];
  let cache: { revision: number; address: string; document: string } | null =
    null;

  const record = (kind: HistoryKind, message: string) => {
    historyId += 1;
    history.push({ id: historyId, kind, message });
  };
  const deliver = ({
    from = 'Maya Chen <maya@example.invalid>',
    subject = 'A note',
    snippet = 'Synthetic snippet',
    unread = true,
    at = Date.UTC(2026, 8, 1) + nextId * 60_000,
  }: {
    readonly from?: string;
    readonly subject?: string;
    readonly snippet?: string;
    readonly unread?: boolean;
    readonly at?: number;
  } = {}) => {
    nextId += 1;
    const id = nextId.toString(16);
    messages.set(id, {
      id,
      from,
      subject,
      snippet,
      internalDate: at,
      labels: new Set(unread ? ['INBOX', 'UNREAD'] : ['INBOX']),
    });
    record('messagesAdded', id);
    return id;
  };
  for (let index = 0; index < count; index += 1) {
    deliver({ subject: `Synthetic message ${index}`, unread: index % 2 === 0 });
  }
  const relabel = (id: string, label: string, add: boolean) => {
    const labels = messages.get(id)?.labels;
    if (labels !== undefined) {
      if (add) {
        labels.add(label);
      } else {
        labels.delete(label);
      }
      record(add ? 'labelsAdded' : 'labelsRemoved', id);
    }
  };

  const readGmail = (
    path: string,
    query: ReadonlyArray<readonly [string, string]>,
  ) => {
    const params = new URLSearchParams(
      query.map(([name, value]) => [name, value]),
    );
    requests.push({ path, query: params });
    const listed = path === 'messages' ? (params.get('pageToken') ?? '') : null;
    const pageFailure = listed === null ? undefined : pageFailures.get(listed);
    if (listed !== null) {
      pageFailures.delete(listed);
    }
    const failure = pageFailure ?? failures.shift();
    if (failure !== undefined) {
      return 'code' in failure
        ? rejection(failure.code)
        : Promise.resolve({
            status: failure.status,
            body: failure.body ?? '{}',
          });
    }
    if (path === 'profile') {
      return respond({ emailAddress: address, historyId: String(historyId) });
    }
    if (path === 'messages') {
      const inbox = Arr.sort(
        [...messages.values()].filter((message) => message.labels.has('INBOX')),
        Order.flip(
          Order.mapInput(
            Order.Number,
            (message: SyntheticMessage) => message.internalDate,
          ),
        ),
      );
      const start = Number(params.get('pageToken') ?? 0);
      const end = start + Number(params.get('maxResults') ?? 100);
      return respond({
        messages: inbox
          .slice(start, end)
          .map(({ id }) => ({ id, threadId: id })),
        ...(end < inbox.length ? { nextPageToken: String(end) } : {}),
      });
    }
    if (path.startsWith('messages/')) {
      const message = messages.get(path.slice('messages/'.length));
      return message === undefined
        ? Promise.resolve({ status: 404, body: '{}' })
        : respond({
            id: message.id,
            threadId: message.id,
            labelIds: [...message.labels],
            snippet: message.snippet,
            historyId: String(historyId),
            internalDate: String(message.internalDate),
            payload: {
              headers: [
                { name: 'From', value: message.from },
                { name: 'Subject', value: message.subject },
              ],
            },
          });
    }
    const start = Number(params.get('startHistoryId'));
    if (path !== 'history' || start < expiredBefore) {
      return Promise.resolve({ status: 404, body: '{}' });
    }
    // Three records per page, so long histories are paginated.
    const records = history.filter((entry) => entry.id > start);
    const page = records.slice(0, 3);
    return respond({
      ...(page.length === 0
        ? {}
        : {
            history: page.map((entry) => ({
              id: String(entry.id),
              [entry.kind]: [{ message: { id: entry.message } }],
            })),
          }),
      ...(records.length > 3 ? { nextPageToken: 'more' } : {}),
      historyId: String(historyId),
    });
  };
  const native = {
    gmailRequest: (path, query, owner) =>
      owner === address
        ? readGmail(path, query)
        : rejection('mailbox-invalidated'),
    openMailbox: () => {
      const code = openFailures.shift();
      return code === undefined
        ? Promise.resolve({
            revision: cache?.revision ?? 0,
            address,
            document: cache?.address === address ? cache.document : null,
          })
        : rejection(code);
    },
    commitMailbox: (owner, expectedRevision, document) => {
      const code = commitFailures.shift();
      if (code !== undefined) {
        return rejection(code);
      }
      if (owner !== address) {
        return rejection('mailbox-invalidated');
      }
      if ((cache?.revision ?? 0) !== expectedRevision) {
        return rejection('conflict');
      }
      cache = { revision: expectedRevision + 1, address: owner, document };
      commits.push(document);
      return Promise.resolve({ ...cache });
    },
  } satisfies NativeGmailMailbox;

  return {
    native,
    requests,
    commits,
    deliver,
    archive: (id: string) => {
      relabel(id, 'INBOX', false);
    },
    markRead: (id: string) => {
      relabel(id, 'UNREAD', false);
    },
    remove: (id: string) => {
      messages.delete(id);
      record('messagesDeleted', id);
    },
    // Gmail no longer has history up to now.
    expireHistory: () => {
      expiredBefore = historyId + 1;
    },
    // Another Gmail mailbox is connected on the device.
    reselect: (next: string) => {
      address = next;
      messages.clear();
    },
    fail: (...next: readonly Failure[]) => {
      failures.push(...next);
    },
    failPage: (pageToken: string, failure: Failure) => {
      pageFailures.set(pageToken, failure);
    },
    failOpen: (code: string) => {
      openFailures.push(code);
    },
    failCommit: (code: string) => {
      commitFailures.push(code);
    },
  };
}
