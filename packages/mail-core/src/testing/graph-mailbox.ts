/* oxlint-disable typescript/prefer-readonly-parameter-types -- Tests change the synthetic mailbox's messages between steps. */
import * as Arr from 'effect/Array';
import * as Base64 from 'effect/encoding/Base64';
import * as Order from 'effect/Order';

import type { NativeGmailMailbox } from '../gmail-inbox.ts';
import type { GraphChange } from '../microsoft-graph.ts';
import type { DraftFile } from '../outgoing-message.ts';

import { assembled, createSyntheticGmail } from './gmail-mailbox.ts';

// A controlled Microsoft Graph mailbox for tests. It answers the Graph requests a Microsoft Inbox
// makes with Graph's response shapes: each folder's list, delta rounds with page and delta links,
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
// Keeping a draft fails once `after` of its files are attached: Graph refuses the next request,
// or the attempt stops there, as when the app quits, leaving the draft behind.
type PrepareFailure = (Failure | { readonly interrupted: true }) &
  Readonly<{ after: number }>;
// An Outlook draft graphPrepare kept: its MIME without files, its Message-ID and attached files.
interface OutlookDraft {
  readonly raw: string;
  readonly messageId: string;
  readonly attachments: SyntheticGraphAttachment[];
}

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

const deltaLink = (folder: string, query: string) =>
  `${graph}/me/mailfolders('${folder}')/messages/delta?${query}`;

// A folder's messages, its delta or one of its messages, by a well-known folder's name or a folder's
// ID, as `mailFolders/{folder}` or `mailFolders('{folder}')`.
const folderMessagesPath =
  /^\/v1\.0\/me\/mail[Ff]olders(?:\/(?<plain>[^/(]+)|\('(?<quoted>[^']+)'\))\/messages(?:\/(?<rest>[^/]+))?$/u;

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
  // Messages Graph accepted, as assembled, the IDs of their Sent Items copies, and the files an
  // Outlook draft carried.
  const sends: Array<{
    raw: string;
    id: string;
    attachments: readonly SyntheticGraphAttachment[];
  }> = [];
  const drafts = new Map<string, OutlookDraft>();
  const prepareFailures: PrepareFailure[] = [];
  const discardFailures: Failure[] = [];
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
    folder = 'inbox',
  }: {
    readonly from?: SyntheticGraphMessage['from'];
    readonly subject?: string;
    readonly preview?: string;
    readonly isRead?: boolean;
    readonly at?: number;
    readonly body?: SyntheticGraphMessage['body'];
    readonly attachments?: readonly SyntheticGraphAttachment[];
    readonly headers?: SyntheticGraphMessage['headers'];
    // A well-known folder's name or a folder's ID.
    readonly folder?: string;
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
      folder,
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
  const inFolder =
    (folder: string) =>
    (
      message: SyntheticGraphMessage | undefined,
    ): message is SyntheticGraphMessage =>
      message?.folder === folder;
  const newest = (folder: string) =>
    Arr.sort(
      [...messages.values()].filter(inFolder(folder)),
      Order.flip(
        Order.mapInput(
          Order.String,
          (message: SyntheticGraphMessage) => message.receivedDateTime,
        ),
      ),
    );

  // The first round lists every message in the folder over several pages; a later round names each
  // message changed since its link, or `@removed` when it left the folder.
  const delta = (url: URL, folder: string) => {
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
          return inFolder(folder)(message)
            ? [listed(message)]
            : [{ id, '@removed': { reason: 'changed' } }];
        }),
        '@odata.deltaLink': deltaLink(
          folder,
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
    const listing = newest(folder);
    const end = offset + pageSize;
    return respond({
      value: listing.slice(offset, end).map(listed),
      ...(end < listing.length
        ? {
            '@odata.nextLink': deltaLink(folder, `$skiptoken=${end}.${issued}`),
          }
        : { '@odata.deltaLink': deltaLink(folder, `$deltatoken=${issued}`) }),
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

  const folderPage = (url: URL, folder: string) => {
    const offset = Number(url.searchParams.get('$skip') ?? 0);
    const until = url.searchParams
      .get('$filter')
      ?.replace('receivedDateTime le ', '');
    const listing = newest(folder).filter(
      (each) =>
        until === undefined ||
        Date.parse(each.receivedDateTime) <= Date.parse(until),
    );
    const next = new URL(url);
    next.searchParams.set('$skip', String(offset + pageSize));
    return respond({
      value: listing.slice(offset, offset + pageSize).map(listed),
      ...(offset + pageSize < listing.length
        ? {
            '@odata.nextLink': next.toString(),
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
  // A well-known folder's name or a folder's ID as a path names it, or undefined when it is gone.
  const pathFolder = (segment: string) => {
    const name = decodeURIComponent(segment);
    const known = name.toLowerCase();
    if (known in wellKnown) {
      return missingFolders.has(known) ? undefined : known;
    }
    return folders.has(name) ? name : undefined;
  };
  // A folder's ID and message count, a folder's own folders, or every top-level folder; a removed
  // folder is gone from each.
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
    const folder = pathFolder(name);
    return folder === undefined
      ? notFound()
      : respond({
          id: folderId(folder),
          totalItemCount: newest(folder).length,
        });
  };
  // A folder's newest messages, its delta, or one of its messages, as a delta change is read; a
  // message that left the folder, and a folder that is gone, are not found.
  const folderMessages = (url: URL) => {
    const groups = folderMessagesPath.exec(url.pathname)?.groups;
    if (groups === undefined) {
      return undefined;
    }
    const folder = pathFolder(groups.plain ?? groups.quoted ?? '');
    if (folder === undefined) {
      return notFound();
    }
    if (groups.rest === undefined) {
      return folderPage(url, folder);
    }
    if (groups.rest === 'delta') {
      return delta(url, folder);
    }
    const found = messages.get(decodeURIComponent(groups.rest));
    return inFolder(folder)(found) ? respond(listed(found)) : notFound();
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
  const accept = (
    raw: string,
    attachments: readonly SyntheticGraphAttachment[] = [],
  ) => {
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
      attachments,
      headers: [],
      ...(messageId === undefined ? {} : { internetMessageId: messageId }),
    };
    sends.push({ raw, id, attachments });
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
    if (
      url.pathname === '/v1.0/me/mailFolders/sentitems/messages' &&
      url.searchParams.get('$filter')?.startsWith('internetMessageId') === true
    ) {
      return sentCopies(url);
    }
    return (
      folderMessages(url) ??
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

  // Graph's sendMail, and its send of a draft, answer 202 Accepted with no body; a lost answer
  // follows acceptance.
  const send = async (
    raw: string,
    attachments?: readonly SyntheticGraphAttachment[],
    sent?: () => void,
  ) => {
    const failure = sendFailures.shift();
    if (failure !== undefined && !('lost' in failure)) {
      return fail(failure);
    }
    sent?.();
    accept(raw, attachments);
    await Promise.resolve();
    return failure === undefined
      ? { status: 202, body: '' }
      : rejection('delivery-unknown');
  };
  // A file as Graph attaches it, or undefined when its bytes no longer verify.
  const attachment = (
    file: DraftFile,
  ): SyntheticGraphAttachment | undefined => {
    const bytes = assets?.(file.asset.id, file.asset.digest);
    return bytes === undefined
      ? undefined
      : {
          name: file.name,
          contentType: file.type,
          bytes: [...bytes],
          ...(file.contentId === undefined
            ? {}
            : { isInline: true, contentId: file.contentId }),
        };
  };

  const native = {
    ...storage.native,
    gmailRequest: () => rejection('unavailable'),
    gmailModify: () => rejection('unavailable'),
    gmailCreateLabel: () => rejection('unavailable'),
    gmailSend: () => rejection('unavailable'),
    graphSend: (outgoing) => {
      if (!('draft' in outgoing)) {
        const raw = assembled(outgoing.segments, assets);
        return raw === undefined ? rejection('attachment-missing') : send(raw);
      }
      const kept = drafts.get(outgoing.draft);
      // A sent draft leaves Drafts for Sent Items.
      return kept === undefined
        ? notFound()
        : send(kept.raw, kept.attachments, () => {
            drafts.delete(outgoing.draft);
          });
    },
    // Deletes the drafts an earlier attempt left under this Message-ID, keeps the MIME as a draft
    // and attaches each file's verified bytes. A refusal deletes the new draft, as native code does.
    graphDiscard: async (messageId) => {
      const failure = discardFailures.shift();
      if (failure !== undefined) {
        return fail(failure);
      }
      for (const [id, each] of drafts) {
        if (each.messageId === messageId) {
          drafts.delete(id);
        }
      }
      return { status: 204, body: '' };
    },
    graphPrepare: async ({ segments, messageId, files }) => {
      const raw = assembled(segments, assets);
      if (raw === undefined) {
        return rejection('attachment-missing');
      }
      for (const [id, each] of drafts) {
        if (each.messageId === messageId) {
          drafts.delete(id);
        }
      }
      nextId += 1;
      const id = `AAMkAGI2-${String(nextId).padStart(4, '0')}_d=`;
      const kept: OutlookDraft = { raw, messageId, attachments: [] };
      drafts.set(id, kept);
      const failure = prepareFailures.shift();
      for (const file of files.slice(0, failure?.after)) {
        const attached = attachment(file);
        if (attached === undefined) {
          drafts.delete(id);
          return rejection('attachment-missing');
        }
        kept.attachments.push(attached);
      }
      await Promise.resolve();
      if (failure === undefined) {
        return { status: 201, body: JSON.stringify({ id }) };
      }
      if ('interrupted' in failure) {
        return rejection('unavailable');
      }
      drafts.delete(id);
      return fail(failure);
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
    // The Outlook drafts Graph keeps, by ID.
    drafts,
    failPrepare: (...next: readonly PrepareFailure[]) => {
      prepareFailures.push(...next);
    },
    failDiscard: (...next: readonly Failure[]) => {
      discardFailures.push(...next);
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
    // The message returns to the Inbox, as when moved back in Outlook.
    restore: (id: string) => {
      change(id, (found) => {
        found.folder = 'inbox';
      });
    },
    // The message moves to a well-known folder's name or a folder's ID, as in Outlook.
    move: (id: string, folder: string) => {
      change(id, (found) => {
        found.folder = folder;
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
