/* oxlint-disable typescript/prefer-readonly-parameter-types -- Tests change the synthetic mailbox's messages between steps. */
import * as Arr from 'effect/Array';
import * as Base64 from 'effect/encoding/Base64';
import * as Order from 'effect/Order';

import type { NativeGmailMailbox } from '../gmail-inbox.ts';

import { createSyntheticGmail } from './gmail-mailbox.ts';

// A controlled Microsoft Graph mailbox for tests. It answers the Graph reads a Microsoft Inbox
// makes with Graph's response shapes: the Inbox list, delta rounds with page and delta links,
// messages and their attachments. The native mailbox cache, bodies and files are the synthetic
// Gmail mailbox's, which follow the same native rules for every provider.
export interface SyntheticGraphAttachment {
  readonly name: string;
  readonly contentType: string;
  readonly bytes: readonly number[];
  readonly isInline?: boolean;
  readonly contentId?: string;
}

interface SyntheticGraphMessage {
  readonly id: string;
  readonly conversationId: string;
  readonly receivedDateTime: string;
  readonly subject: string;
  readonly bodyPreview: string;
  readonly from: Readonly<{ name: string; address: string }>;
  isRead: boolean;
  inbox: boolean;
  readonly body: Readonly<{ contentType: 'html' | 'text'; content: string }>;
  readonly attachments: readonly SyntheticGraphAttachment[];
  readonly headers: ReadonlyArray<Readonly<{ name: string; value: string }>>;
}

type Failure =
  | { readonly status: number; readonly body?: string }
  | { readonly code: string };

const graph = 'https://graph.microsoft.com/v1.0';

const respond = (body: unknown) =>
  Promise.resolve({ status: 200, body: JSON.stringify(body) });
const notFound = () =>
  Promise.resolve({
    status: 404,
    body: JSON.stringify({ error: { code: 'ErrorItemNotFound' } }),
  });
const rejection = (code: string) =>
  Promise.reject(Object.assign(new Error('Synthetic failure'), { code }));

const deltaLink = (query: string) =>
  `${graph}/me/mailfolders('inbox')/messages/delta?${query}`;

// Graph's attachment size counts more than the file's bytes.
const graphSize = (attachment: SyntheticGraphAttachment) =>
  attachment.bytes.length + 120;

export function createSyntheticGraph({
  address = 'casey@example.invalid',
  messages: count = 0,
  pageSize = 2,
}: {
  readonly address?: string;
  readonly messages?: number;
  // Items per list and delta page, as Graph's odata.maxpagesize preference allows.
  readonly pageSize?: number;
} = {}) {
  const storage = createSyntheticGmail({ address });
  const messages = new Map<string, SyntheticGraphMessage>();
  // Every change in order; a delta link names the change it was issued after.
  const changes: string[] = [];
  let expiredBefore = 0;
  // Each later round, even an empty one, returns a link Graph has not issued before.
  let rotating = false;
  let rounds = 0;
  let nextId = 0;
  const failures: Failure[] = [];
  const requests: URL[] = [];

  const deliver = ({
    from = { name: 'Rowan Hale', address: 'rowan@example.invalid' },
    subject = 'A note',
    preview = 'Synthetic preview',
    isRead = false,
    at = Date.UTC(2026, 8, 1) + (nextId + 1) * 60_000,
    body = { contentType: 'text', content: `${preview}\n\nSynthetic body.` },
    attachments = [],
    headers = [],
  }: {
    readonly from?: SyntheticGraphMessage['from'];
    readonly subject?: string;
    readonly preview?: string;
    readonly isRead?: boolean;
    readonly at?: number;
    readonly body?: SyntheticGraphMessage['body'];
    readonly attachments?: readonly SyntheticGraphAttachment[];
    readonly headers?: SyntheticGraphMessage['headers'];
  } = {}) => {
    nextId += 1;
    // Graph IDs are long URL-safe base64 text.
    const id = `AAMkAGI2-${String(nextId).padStart(4, '0')}_x=`;
    messages.set(id, {
      id,
      conversationId: `conversation-${nextId}`,
      receivedDateTime: new Date(at).toISOString().replace('.000Z', 'Z'),
      subject,
      bodyPreview: preview,
      from,
      isRead,
      inbox: true,
      body,
      attachments,
      headers,
    });
    changes.push(id);
    return id;
  };
  for (let index = 0; index < count; index += 1) {
    deliver({ subject: `Synthetic message ${index}`, isRead: index % 2 === 1 });
  }
  const change = (
    id: string,
    update: (message: SyntheticGraphMessage) => void,
  ) => {
    const message = messages.get(id);
    if (message !== undefined) {
      update(message);
      changes.push(id);
    }
  };

  const listed = ({
    id,
    conversationId,
    receivedDateTime,
    subject,
    bodyPreview,
    from,
    isRead,
  }: SyntheticGraphMessage) => ({
    '@odata.etag': 'W/"synthetic"',
    id,
    conversationId,
    receivedDateTime,
    subject,
    bodyPreview,
    isRead,
    from: { emailAddress: from },
  });
  const newest = () =>
    Arr.sort(
      [...messages.values()].filter(({ inbox }) => inbox),
      Order.flip(
        Order.mapInput(
          Order.String,
          (message: SyntheticGraphMessage) => message.receivedDateTime,
        ),
      ),
    );

  // The first round lists every Inbox message over several pages; a later round names each
  // message changed since its link, or `@removed` when it left the Inbox.
  const delta = (url: URL) => {
    const token = url.searchParams.get('$deltatoken');
    if (token !== null) {
      const after = Number(token.split('r')[0]);
      if (after < expiredBefore) {
        return Promise.resolve({
          status: 410,
          body: JSON.stringify({ error: { code: 'SyncStateNotFound' } }),
        });
      }
      const changed = [...new Set(changes.slice(after))];
      return respond({
        value: changed.flatMap((id): unknown[] => {
          const message = messages.get(id);
          return message?.inbox === true
            ? [listed(message)]
            : [{ id, '@removed': { reason: 'changed' } }];
        }),
        '@odata.deltaLink': deltaLink(
          rotating
            ? `$deltatoken=${changes.length}r${(rounds += 1)}`
            : `$deltatoken=${changes.length}`,
        ),
      });
    }
    const [offset = 0, issued = changes.length] = (
      url.searchParams.get('$skiptoken') ?? ''
    )
      .split('.')
      .filter(Boolean)
      .map(Number);
    const inbox = newest();
    const end = offset + pageSize;
    return respond({
      value: inbox.slice(offset, end).map(listed),
      ...(end < inbox.length
        ? { '@odata.nextLink': deltaLink(`$skiptoken=${end}.${issued}`) }
        : { '@odata.deltaLink': deltaLink(`$deltatoken=${issued}`) }),
    });
  };

  const message = (id: string, path: readonly string[], offset: number) => {
    const found = messages.get(id);
    if (found === undefined) {
      return notFound();
    }
    const attachments = found.attachments.map((attachment, index) => ({
      attachment,
      id: `${found.id}-attachment-${index}`,
    }));
    if (path.length === 0) {
      return respond({
        id,
        body: found.body,
        from: { emailAddress: found.from },
        toRecipients: [{ emailAddress: { name: 'Casey', address } }],
        ccRecipients: [],
        replyTo: [],
        internetMessageId: `<${id}@example.invalid>`,
        internetMessageHeaders: found.headers,
        // Graph does not count inline attachments.
        hasAttachments: found.attachments.some(
          ({ isInline }) => isInline !== true,
        ),
      });
    }
    if (path.length === 1) {
      return respond({
        value: attachments
          .slice(offset, offset + pageSize)
          .map(({ attachment, id: attachmentId }) => ({
            '@odata.type': '#microsoft.graph.fileAttachment',
            id: attachmentId,
            name: attachment.name,
            contentType: attachment.contentType,
            size: graphSize(attachment),
            isInline: attachment.isInline === true,
            contentId: attachment.contentId ?? null,
          })),
        ...(offset + pageSize < attachments.length
          ? {
              '@odata.nextLink': `${graph}/me/messages/${id}/attachments?$skip=${offset + pageSize}`,
            }
          : {}),
      });
    }
    const file = attachments.find(
      ({ id: attachmentId }) => attachmentId === path[1],
    );
    return file === undefined
      ? notFound()
      : respond({
          '@odata.type': '#microsoft.graph.fileAttachment',
          id: file.id,
          contentId: file.attachment.contentId ?? null,
          contentBytes: Base64.encode(Uint8Array.from(file.attachment.bytes)),
        });
  };

  const fail = (failure: Failure) =>
    'code' in failure
      ? rejection(failure.code)
      : Promise.resolve({ status: failure.status, body: failure.body ?? '{}' });

  const inboxPage = (url: URL) => {
    const offset = Number(url.searchParams.get('$skip') ?? 0);
    const inbox = newest();
    return respond({
      value: inbox.slice(offset, offset + pageSize).map(listed),
      ...(offset + pageSize < inbox.length
        ? {
            '@odata.nextLink': `${graph}/me/mailfolders/inbox/messages?$skip=${offset + pageSize}`,
          }
        : {}),
    });
  };

  const messageAt = (url: URL) => {
    const groups =
      /^\/v1\.0\/me\/messages\/(?<id>[^/]+)(?:\/(?<list>attachments)(?:\/(?<attachment>[^/]+))?)?$/u.exec(
        url.pathname,
      )?.groups;
    return groups?.id === undefined
      ? notFound()
      : message(
          decodeURIComponent(groups.id),
          [groups.list, groups.attachment].filter((part) => part !== undefined),
          Number(url.searchParams.get('$skip') ?? 0),
        );
  };

  const read = (url: URL) => {
    const failure = failures.shift();
    if (failure !== undefined) {
      return fail(failure);
    }
    if (url.pathname.toLowerCase() === '/v1.0/me/mailfolders/inbox/messages') {
      return inboxPage(url);
    }
    if (url.pathname.endsWith('/messages/delta')) {
      return delta(url);
    }
    if (
      url.pathname
        .toLowerCase()
        .startsWith('/v1.0/me/mailfolders/inbox/messages/')
    ) {
      const id = decodeURIComponent(url.pathname.split('/').at(-1) ?? '');
      const found = messages.get(id);
      return found?.inbox === true ? respond(listed(found)) : notFound();
    }
    return messageAt(url);
  };

  const native = {
    ...storage.native,
    gmailRequest: () => rejection('unavailable'),
    gmailModify: () => rejection('unavailable'),
    gmailSend: () => rejection('unavailable'),
    graphRequest: (url, owner) => {
      if (owner.signal?.aborted === true) {
        throw new Error('The Graph request was cancelled.');
      }
      const parsed = new URL(url);
      requests.push(parsed);
      return read(parsed);
    },
  } satisfies NativeGmailMailbox;

  return {
    native,
    requests,
    commits: storage.commits,
    savedFiles: storage.savedFiles,
    cachedBodies: storage.cachedBodies,
    deliver,
    markRead: (id: string) => {
      change(id, (found) => {
        found.isRead = true;
      });
    },
    // The message leaves the Inbox, as when moved or deleted in Outlook.
    remove: (id: string) => {
      change(id, (found) => {
        found.inbox = false;
      });
    },
    // Later delta rounds return a fresh link, even when nothing changed.
    rotateDelta: () => {
      rotating = true;
    },
    // Graph no longer accepts delta links issued so far.
    expireDelta: () => {
      expiredBefore = changes.length + 1;
    },
    fail: (...next: readonly Failure[]) => {
      failures.push(...next);
    },
  };
}
