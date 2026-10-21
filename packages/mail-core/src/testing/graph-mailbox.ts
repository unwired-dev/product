/* oxlint-disable typescript/prefer-readonly-parameter-types -- Tests change the synthetic mailbox's messages between steps. */
import * as Arr from 'effect/Array';
import * as Base64 from 'effect/encoding/Base64';
import * as Order from 'effect/Order';

import type { NativeGmailMailbox } from '../gmail-inbox.ts';
import type { GraphChange } from '../microsoft-graph.ts';

import { assembled, createSyntheticGmail } from './gmail-mailbox.ts';

// A controlled Microsoft Graph mailbox for tests. It answers the Graph requests a Microsoft Inbox
// makes with Graph's response shapes: the Inbox list, delta rounds with page and delta links,
// messages and their attachments, folders, search, and read-state and move changes. The native
// mailbox cache, bodies and files are the synthetic Gmail mailbox's, which follow the same native
// rules for every provider.
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
  // A well-known folder's name, or a folder's ID.
  folder: string;
  readonly body: Readonly<{ contentType: 'html' | 'text'; content: string }>;
  readonly attachments: readonly SyntheticGraphAttachment[];
  readonly headers: ReadonlyArray<Readonly<{ name: string; value: string }>>;
  // A sent message's own Message-ID, which Sent Items are searched by.
  readonly internetMessageId?: string;
}

type Failure =
  | { readonly status: number; readonly body?: string }
  | { readonly code: string };
// A change Graph applies but whose reply never arrives.
type ModifyFailure = Failure | { readonly lost: true };
// A send Graph accepts but whose reply never arrives.
type SendFailure = Failure | { readonly lost: true };

const wellKnown: Readonly<Record<string, string>> = {
  inbox: 'Inbox',
  archive: 'Archive',
  deleteditems: 'Deleted Items',
  junkemail: 'Junk Email',
  drafts: 'Drafts',
  sentitems: 'Sent Items',
  outbox: 'Outbox',
};
// Graph names a well-known folder by its own ID in parentFolderId.
const folderId = (folder: string) =>
  folder in wellKnown ? `AQMkFolder-${folder}=` : folder;

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
  inboxName = 'Inbox',
  assets,
}: {
  readonly address?: string;
  readonly messages?: number;
  // Items per list and delta page, as Graph's odata.maxpagesize preference allows.
  readonly pageSize?: number;
  // The provider's localized display name, independent of the app's language.
  readonly inboxName?: string;
  // A Draft Asset's verified bytes as native code reads them; undefined when they no longer verify.
  readonly assets?: (id: string, digest: string) => Uint8Array | undefined;
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
  const modifyFailures: ModifyFailure[] = [];
  const requests: URL[] = [];
  // Changes Graph received, in order, and the search texts it was asked for.
  const modifies: Array<Readonly<{ message: string } & GraphChange>> = [];
  const searches: string[] = [];
  // The mailbox's own folders by ID, and well-known folders this mailbox lacks.
  const folders = new Map<
    string,
    Readonly<{ name: string; parent?: string }>
  >();
  const missingFolders = new Set<string>();
  let nextFolder = 0;
  // Messages Graph accepted from sendMail, as assembled, and the IDs of their Sent Items copies.
  const sends: Array<{ raw: string; id: string }> = [];
  const sendFailures: SendFailure[] = [];
  // Accepted messages whose Sent Items copy Microsoft has not filed yet.
  let filing: SyntheticGraphMessage[] | undefined = undefined;

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
      folder: 'inbox',
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
  const inInbox = (
    message: SyntheticGraphMessage | undefined,
  ): message is SyntheticGraphMessage => message?.folder === 'inbox';
  const newest = () =>
    Arr.sort(
      [...messages.values()].filter(inInbox),
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
          return inInbox(message)
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

  const placement = ({ id, folder, isRead }: SyntheticGraphMessage) => ({
    id,
    parentFolderId: folderId(folder),
    isRead,
  });
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
        internetMessageId: found.internetMessageId ?? `<${id}@example.invalid>`,
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

  // A well-known folder's ID, or every top-level folder; a removed folder is gone from both.
  // The folders inside `parent`, a folder's ID, or the top-level ones, each with its count of
  // folders of its own.
  const children = (parent: string | undefined) => {
    const own = (id: string) =>
      [...folders.values()].filter(
        (folder) =>
          folder.parent !== undefined && folderId(folder.parent) === id,
      ).length;
    return [
      ...(parent === undefined
        ? Object.entries(wellKnown)
            .filter(([known]) => !missingFolders.has(known))
            .map(([known, displayName]) => ({
              id: folderId(known),
              displayName: known === 'inbox' ? inboxName : displayName,
            }))
        : []),
      ...[...folders]
        .filter(
          ([, folder]) =>
            (folder.parent === undefined
              ? undefined
              : folderId(folder.parent)) === parent,
        )
        .map(([id, folder]) => ({ id, displayName: folder.name })),
    ].map((folder) => ({ ...folder, childFolderCount: own(folder.id) }));
  };
  // A well-known folder's ID, a folder's own folders, or every top-level folder; a removed folder
  // is gone from each.
  const folderRead = (url: URL) => {
    const path =
      /^\/v1\.0\/me\/mail[Ff]olders(?:\/(?<name>[^/]+)(?<nested>\/childFolders)?)?$/u.exec(
        url.pathname,
      );
    if (path === null) {
      return undefined;
    }
    const { name, nested } = path.groups ?? {};
    if (name === undefined || nested !== undefined) {
      return respond({ value: children(name) });
    }
    return name in wellKnown && !missingFolders.has(name)
      ? respond({ id: folderId(name) })
      : notFound();
  };
  // One Inbox message, as a delta change is read; one that left the Inbox is not found there.
  const inboxMessage = (url: URL) => {
    if (
      !url.pathname
        .toLowerCase()
        .startsWith('/v1.0/me/mailfolders/inbox/messages/')
    ) {
      return undefined;
    }
    const found = messages.get(
      decodeURIComponent(url.pathname.split('/').at(-1) ?? ''),
    );
    return inInbox(found) ? respond(listed(found)) : notFound();
  };
  // Where a message is, as organizing reads it back.
  const placementRead = (url: URL) => {
    if (url.searchParams.get('$select')?.includes('parentFolderId') !== true) {
      return undefined;
    }
    const found = messages.get(
      decodeURIComponent(url.pathname.split('/').at(-1) ?? ''),
    );
    return found === undefined ? notFound() : respond(placement(found));
  };
  // Graph's search of every folder: each quoted word must appear in the sender, subject or preview.
  const searchPage = (url: URL) => {
    const search = url.searchParams.get('$search');
    if (url.pathname !== '/v1.0/me/messages' || search === null) {
      return undefined;
    }
    searches.push(search);
    const words = search.replaceAll(/^"|"$/gu, '').toLowerCase().split(/\s+/u);
    const matching = Arr.sort(
      [...messages.values()].filter((each) =>
        words.every((word) =>
          [each.from.name, each.from.address, each.subject, each.bodyPreview]
            .join(' ')
            .toLowerCase()
            .includes(word),
        ),
      ),
      Order.flip(
        Order.mapInput(
          Order.String,
          (each: SyntheticGraphMessage) => each.receivedDateTime,
        ),
      ),
    );
    const offset = Number(url.searchParams.get('$skiptoken') ?? 0);
    const end = offset + pageSize;
    return respond({
      value: matching.slice(offset, end).map((each) => ({
        ...listed(each),
        parentFolderId: folderId(each.folder),
      })),
      ...(end < matching.length
        ? {
            '@odata.nextLink': `${graph}/me/messages?$search=${encodeURIComponent(search)}&$skiptoken=${end}`,
          }
        : {}),
    });
  };

  // Sent Items' messages with one Message-ID, as the Outbox looks for a message it sent.
  const sentCopies = (url: URL) => {
    const id = /^internetMessageId eq '(?<id>.+)'$/u.exec(
      url.searchParams.get('$filter') ?? '',
    )?.groups?.id;
    return respond({
      value: [...messages.values()]
        .filter(
          (each) =>
            each.folder === 'sentitems' &&
            each.internetMessageId !== undefined &&
            each.internetMessageId === id?.replaceAll("''", "'"),
        )
        .map(({ id: copy }) => ({ id: copy })),
    });
  };
  // Graph keeps an accepted message in Sent Items, under the Message-ID the message names.
  const accept = (raw: string) => {
    nextId += 1;
    const id = `AAMkAGI2-${String(nextId).padStart(4, '0')}_s=`;
    const header = (name: string) =>
      new RegExp(`^${name}: (?<value>.*)\\r$`, 'mu').exec(raw)?.groups?.value;
    const messageId = header('Message-ID');
    const copy: SyntheticGraphMessage = {
      id,
      conversationId: `conversation-${nextId}`,
      receivedDateTime: new Date(Date.UTC(2026, 8, 1) + nextId * 60_000)
        .toISOString()
        .replace('.000Z', 'Z'),
      subject: header('Subject') ?? '',
      bodyPreview: '',
      from: { name: '', address },
      isRead: true,
      folder: 'sentitems',
      body: { contentType: 'text', content: '' },
      attachments: [],
      headers: [],
      ...(messageId === undefined ? {} : { internetMessageId: messageId }),
    };
    sends.push({ raw, id });
    if (filing === undefined) {
      messages.set(id, copy);
    } else {
      filing.push(copy);
    }
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
    if (url.pathname === '/v1.0/me/mailFolders/sentitems/messages') {
      return sentCopies(url);
    }
    return (
      inboxMessage(url) ??
      folderRead(url) ??
      searchPage(url) ??
      placementRead(url) ??
      messageAt(url)
    );
  };

  // Applies one change as Graph does, answering with the message afterwards. A move to a folder
  // that does not exist is refused; a missing message is not found.
  const apply = (request: Readonly<{ message: string } & GraphChange>) => {
    const found = messages.get(request.message);
    if (found === undefined) {
      return notFound();
    }
    if ('read' in request) {
      found.isRead = request.read;
      changes.push(found.id);
      return respond(placement(found));
    }
    const destination =
      request.folder in wellKnown && !missingFolders.has(request.folder)
        ? request.folder
        : [...folders.keys()].find((id) => id === request.folder);
    if (destination === undefined) {
      return Promise.resolve({
        status: 400,
        body: JSON.stringify({ error: { code: 'ErrorInvalidIdMalformed' } }),
      });
    }
    found.folder = destination;
    changes.push(found.id);
    return Promise.resolve({
      status: 201,
      body: JSON.stringify(placement(found)),
    });
  };

  const native = {
    ...storage.native,
    gmailRequest: () => rejection('unavailable'),
    gmailModify: () => rejection('unavailable'),
    gmailSend: () => rejection('unavailable'),
    // Graph's sendMail answers 202 Accepted with no body.
    graphSend: async (outgoing) => {
      const raw = assembled(outgoing.segments, assets);
      if (raw === undefined) {
        return rejection('attachment-missing');
      }
      const failure = sendFailures.shift();
      if (failure !== undefined && !('lost' in failure)) {
        return fail(failure);
      }
      accept(raw);
      await Promise.resolve();
      return failure === undefined
        ? { status: 202, body: '' }
        : rejection('delivery-unknown');
    },
    graphModify: async (request) => {
      modifies.push(request);
      const failure = modifyFailures.shift();
      if (failure === undefined) {
        return apply(request);
      }
      if ('lost' in failure) {
        await apply(request);
        return rejection('unavailable');
      }
      return fail(failure);
    },
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
    modifies,
    searches,
    // Messages Graph accepted, in order.
    sends,
    failSend: (...next: readonly SendFailure[]) => {
      sendFailures.push(...next);
    },
    // Microsoft files Sent Items copies only once `fileSentCopies` is called, as when it is slow.
    holdSentCopies: () => {
      filing ??= [];
    },
    fileSentCopies: () => {
      for (const copy of filing ?? []) {
        messages.set(copy.id, copy);
      }
      filing = undefined;
    },
    markRead: (id: string) => {
      change(id, (found) => {
        found.isRead = true;
      });
    },
    // The message leaves the Inbox, as when moved or deleted in Outlook.
    remove: (id: string) => {
      change(id, (found) => {
        found.folder = 'deleteditems';
      });
    },
    // The message is deleted for good, as when emptied from Deleted Items in Outlook.
    purge: (id: string) => {
      if (messages.delete(id)) {
        changes.push(id);
      }
    },
    // Where a message is now: a well-known folder's name or a folder's ID.
    folderOf: (id: string) => messages.get(id)?.folder,
    // A folder of the mailbox's own, inside `parent` when given: a well-known folder's name or a
    // folder's ID. Resolves its ID.
    createFolder: (name: string, parent?: string) => {
      nextFolder += 1;
      const id = `AQMkUserFolder-${nextFolder}_${name.length}=`;
      folders.set(id, parent === undefined ? { name } : { name, parent });
      return id;
    },
    deleteFolder: (id: string) => {
      folders.delete(id);
    },
    // A mailbox without this well-known folder, as one without Archive.
    withoutFolder: (name: string) => {
      missingFolders.add(name);
    },
    failModify: (...next: readonly ModifyFailure[]) => {
      modifyFailures.push(...next);
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
