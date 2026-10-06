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

// A modify Gmail applies before the connection drops, so its response is lost.
type ModifyFailure = Failure | { readonly lost: true };

const systemLabels = [
  'INBOX',
  'SPAM',
  'TRASH',
  'UNREAD',
  'STARRED',
  'IMPORTANT',
  'CATEGORY_UPDATES',
];

const respond = (body: unknown) =>
  Promise.resolve({ status: 200, body: JSON.stringify(body) });

const notFound = () => Promise.resolve({ status: 404, body: '{}' });

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
  const modifies: Array<{
    id: string;
    add: readonly string[];
    remove: readonly string[];
  }> = [];
  const modifyFailures: ModifyFailure[] = [];
  const userLabels = new Map<string, string>();
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

  const newestInbox = () =>
    Arr.sort(
      [...messages.values()].filter((message) => message.labels.has('INBOX')),
      Order.flip(
        Order.mapInput(
          Order.Number,
          (message: SyntheticMessage) => message.internalDate,
        ),
      ),
    );
  const listPage = (params: URLSearchParams) => {
    const inbox = newestInbox();
    const start = Number(params.get('pageToken') ?? 0);
    const end = start + Number(params.get('maxResults') ?? 100);
    return respond({
      messages: inbox.slice(start, end).map(({ id }) => ({ id, threadId: id })),
      ...(end < inbox.length ? { nextPageToken: String(end) } : {}),
    });
  };
  const metadata = (id: string) => {
    const message = messages.get(id);
    if (message === undefined) {
      return notFound();
    }
    return respond({
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
  };
  // Three records per page, so long histories are paginated.
  const historyPage = (params: URLSearchParams) => {
    const start = Number(params.get('startHistoryId'));
    if (start < expiredBefore) {
      return notFound();
    }
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
  // A queued failure, or one registered for the requested list page.
  const nextFailure = (path: string, params: URLSearchParams) => {
    const listed = path === 'messages' ? (params.get('pageToken') ?? '') : null;
    const pageFailure = listed === null ? undefined : pageFailures.get(listed);
    if (listed !== null) {
      pageFailures.delete(listed);
    }
    return pageFailure ?? failures.shift();
  };
  const respondTo = (path: string, params: URLSearchParams) => {
    if (path === 'profile') {
      return respond({ emailAddress: address, historyId: String(historyId) });
    }
    if (path === 'messages') {
      return listPage(params);
    }
    if (path.startsWith('messages/')) {
      return metadata(path.slice('messages/'.length));
    }
    if (path === 'labels') {
      return respond({
        labels: [
          ...systemLabels.map((id) => ({ id, name: id, type: 'system' })),
          ...[...userLabels].map(([id, name]) => ({ id, name, type: 'user' })),
        ],
      });
    }
    return path === 'history' ? historyPage(params) : notFound();
  };
  // Gmail's modify: unknown labels are a bad request and a missing message is not found.
  const modifyMessage = (
    id: string,
    add: readonly string[],
    remove: readonly string[],
  ) => {
    const message = messages.get(id);
    if (message === undefined) {
      return notFound();
    }
    if (
      [...add, ...remove].some(
        (label) => !systemLabels.includes(label) && !userLabels.has(label),
      )
    ) {
      return Promise.resolve({ status: 400, body: '{}' });
    }
    for (const label of remove) {
      relabel(id, label, false);
    }
    for (const label of add) {
      relabel(id, label, true);
    }
    return respond({
      id,
      threadId: id,
      labelIds: [...message.labels],
    });
  };
  const readGmail = (
    path: string,
    query: ReadonlyArray<readonly [string, string]>,
  ) => {
    const params = new URLSearchParams(
      query.map(([name, value]) => [name, value]),
    );
    requests.push({ path, query: params });
    const failure = nextFailure(path, params);
    if (failure === undefined) {
      return respondTo(path, params);
    }
    return 'code' in failure
      ? rejection(failure.code)
      : Promise.resolve({ status: failure.status, body: failure.body ?? '{}' });
  };
  let generation = 0;
  const native = {
    gmailRequest: (path, query, owner) =>
      owner.address === address && owner.generation === String(generation)
        ? readGmail(path, query)
        : rejection('mailbox-invalidated'),
    gmailModify: async ({ message: id, add, remove }, owner) => {
      if (
        owner.address !== address ||
        owner.generation !== String(generation)
      ) {
        return rejection('mailbox-invalidated');
      }
      modifies.push({ id, add, remove });
      const failure = modifyFailures.shift();
      if (failure === undefined) {
        return modifyMessage(id, add, remove);
      }
      if ('lost' in failure) {
        await modifyMessage(id, add, remove);
        return rejection('unavailable');
      }
      return 'code' in failure
        ? rejection(failure.code)
        : { status: failure.status, body: failure.body ?? '{}' };
    },
    openMailbox: () => {
      const code = openFailures.shift();
      return code === undefined
        ? Promise.resolve({
            revision: cache?.revision ?? 0,
            address,
            generation: String(generation),
            owner: `synthetic-owner-${generation}`,
            document: cache?.address === address ? cache.document : null,
          })
        : rejection(code);
    },
    commitMailbox: (owner, expectedRevision, document) => {
      const code = commitFailures.shift();
      if (code !== undefined) {
        return rejection(code);
      }
      if (
        owner.address !== address ||
        owner.generation !== String(generation)
      ) {
        return rejection('mailbox-invalidated');
      }
      if ((cache?.revision ?? 0) !== expectedRevision) {
        return rejection('conflict');
      }
      cache = {
        revision: expectedRevision + 1,
        address: owner.address,
        document,
      };
      commits.push(document);
      return Promise.resolve({
        ...cache,
        generation: String(generation),
        owner: `synthetic-owner-${generation}`,
      });
    },
  } satisfies NativeGmailMailbox;

  return {
    native,
    requests,
    commits,
    // Modify requests that reached Gmail, in order.
    modifies,
    deliver,
    labelsOf: (id: string) => [...(messages.get(id)?.labels ?? [])],
    // A label created in Gmail; its ID never matches its name.
    createLabel: (name: string) => {
      const id = `Label_${userLabels.size + 1}`;
      userLabels.set(id, name);
      return id;
    },
    deleteLabel: (id: string) => {
      userLabels.delete(id);
      for (const message of messages.values()) {
        if (message.labels.delete(id)) {
          record('labelsRemoved', message.id);
        }
      }
    },
    // A label change made in Gmail itself, outside this device.
    setLabel: (id: string, label: string, applied: boolean) => {
      relabel(id, label, applied);
    },
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
      generation += 1;
      cache = null;
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
    failModify: (...next: readonly ModifyFailure[]) => {
      modifyFailures.push(...next);
    },
  };
}
