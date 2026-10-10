import * as Arr from 'effect/Array';
import * as Base64Url from 'effect/encoding/Base64Url';
import * as Order from 'effect/Order';
import * as Result from 'effect/Result';

import type { NativeGmailMailbox, OutgoingSend } from '../gmail-inbox.ts';
import type { NativeGmailMailboxes } from '../mailboxes.ts';

import { base64Lines } from '../outgoing-message.ts';
import { createSyntheticRemoteContent } from './remote-content.ts';

// A controlled Gmail API and native mailbox cache for tests. It answers the Gmail reads the
// Inbox makes with Gmail's response shapes and keeps the cache's revision and address rules.
interface SyntheticMessage {
  readonly id: string;
  readonly from: string;
  readonly subject: string;
  readonly snippet: string;
  readonly internalDate: number;
  readonly labels: Set<string>;
  readonly content: SyntheticContent;
  // Further top-level headers, such as To, Cc, Reply-To, Message-ID and References.
  readonly headers: ReadonlyArray<Readonly<{ name: string; value: string }>>;
}

// A message's readable content: HTML and/or plain text, encoded in `charset`. A `separate` part
// is served through Gmail's attachments resource, as Gmail does for large parts. A `single`
// message is one readable part; otherwise the alternatives sit in a related scope with any
// inline `images`, beside an attached file.
export interface SyntheticContent {
  readonly html?: string;
  readonly text?: string;
  readonly charset?: 'utf8' | 'latin1';
  readonly separate?: boolean;
  readonly single?: boolean;
  // Content-Disposition headers on the readable parts, as some senders send; a list repeats
  // the header.
  readonly disposition?: string | readonly string[];
  readonly images?: ReadonlyArray<{
    readonly contentId: string;
    readonly mimeType: string;
    readonly bytes: readonly number[];
    // Declared size when it differs from the bytes, as a truncated download would.
    readonly size?: number;
  }>;
  // Attached files after the default `notes.txt`, served through the attachments resource.
  readonly attachments?: ReadonlyArray<{
    readonly filename: string;
    readonly mimeType: string;
    readonly bytes: readonly number[];
    readonly disposition?: string;
    // Declared size when it differs from the bytes, as a truncated download would.
    readonly size?: number;
    // Served data replacing the bytes' encoding, as a damaged response would.
    readonly data?: string;
  }>;
}

// The default attached file every multipart message carries.
export const notesText = 'Notes here.\n';

const base64Url = (text: string, charset: SyntheticContent['charset']) =>
  Base64Url.encode(
    charset === 'latin1'
      ? Uint8Array.from(text, (character) => character.codePointAt(0) ?? 0)
      : text,
  );

const byteSize = (text: string, charset: SyntheticContent['charset']) =>
  charset === 'latin1' ? text.length : new TextEncoder().encode(text).length;

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
// A send Gmail accepts before the connection drops, so native code cannot tell the outcome.
type SendFailure = Failure | { readonly lost: true };

const systemLabels = [
  'INBOX',
  'SPAM',
  'TRASH',
  'UNREAD',
  'STARRED',
  'IMPORTANT',
  'CATEGORY_UPDATES',
];

const bodyKey = (owner: string, id: string) => `${owner}\n${id}`;

const respond = (body: unknown) =>
  Promise.resolve({ status: 200, body: JSON.stringify(body) });

const notFound = () => Promise.resolve({ status: 404, body: '{}' });

const rejection = (code: string) =>
  Promise.reject(Object.assign(new Error('Synthetic failure'), { code }));

// An inline image part, or a readable part Gmail served separately.
const imageAttachment = (content: SyntheticContent, attachmentId: string) => {
  const image = content.images?.[Number(attachmentId.slice('image-'.length))];
  return image === undefined
    ? notFound()
    : respond({
        size: image.size ?? image.bytes.length,
        data: Base64Url.encode(Uint8Array.from(image.bytes)),
      });
};
const fileAttachment = (content: SyntheticContent, attachmentId: string) => {
  if (attachmentId === 'attached-file') {
    return respond({
      size: notesText.length,
      data: Base64Url.encode(notesText),
    });
  }
  const file =
    content.attachments?.[Number(attachmentId.slice('file-'.length))];
  return file === undefined
    ? notFound()
    : respond({
        size: file.size ?? file.bytes.length,
        data: file.data ?? Base64Url.encode(Uint8Array.from(file.bytes)),
      });
};
const partAttachment = (content: SyntheticContent, attachmentId: string) => {
  const text = attachmentId === 'part-0-0' ? content.text : content.html;
  return text === undefined
    ? notFound()
    : respond({
        size: byteSize(text, content.charset),
        data: base64Url(text, content.charset),
      });
};
export function createSyntheticGmail({
  address: initialAddress = 'alex@example.invalid',
  messages: count = 0,
  assets,
}: {
  readonly address?: string;
  readonly messages?: number;
  // Verified Draft Asset bytes, as native code reads them from Draft storage to send.
  readonly assets?: (id: string, digest: string) => Uint8Array | undefined;
} = {}) {
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
  // Messages Gmail accepted from messages.send, as assembled, with the thread each joined.
  const sends: Array<{ raw: string; threadId?: string; id: string }> = [];
  const sendFailures: SendFailure[] = [];
  const userLabels = new Map<string, string>();
  let nextLabel = 0;
  const commits: string[] = [];
  let cache: { revision: number; address: string; document: string } | null =
    null;
  // The Bounded Encrypted Body Cache, keyed by address and message ID.
  const bodies = new Map<string, string>();
  // The bodies stored as prefetch exclusion markers, in native's own tier.
  const excludedBodies = new Set<string>();
  const bodyFailures: string[] = [];
  const retainFailures: string[] = [];
  // Downloaded Attachments native code holds for this connection, by opaque file name, and the
  // system presentations requested for them.
  const savedFiles = new Map<string, { name: string; bytes: Uint8Array }>();
  const presentations: Array<{ name: string; action: string }> = [];
  let nextFile = 0;
  const saveFailures: string[] = [];
  const presentFailures: string[] = [];
  // Each body commit's tier and protected working set, as native admission receives them.
  const bodyCommits: Array<{
    id: string;
    tier: string;
    protectedIds: readonly string[];
  }> = [];
  // Each prune's protected working set, as native retention receives it.
  const bodyRetains: Array<readonly string[]> = [];
  // Messages whose bodies native admission refuses, as a full cache would.
  const refusedBodies = new Set<string>();

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
    content = { text: `${snippet}\n\nSynthetic body.` },
    headers = {},
  }: {
    readonly from?: string;
    readonly subject?: string;
    readonly snippet?: string;
    readonly unread?: boolean;
    readonly at?: number;
    readonly content?: SyntheticContent;
    readonly headers?: Readonly<Record<string, string>>;
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
      content,
      headers: Object.entries(headers).map(([name, value]) => ({
        name,
        value,
      })),
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
  // Gmail's own search covers all mail outside spam and trash, sender, subject and content alike.
  // Every word must appear, ignoring case; real Gmail operators are beyond this stand-in.
  const searched = (query: string) => {
    const words = query.toLowerCase().split(/\s+/u).filter(Boolean);
    return Arr.sort(
      [...messages.values()].filter(
        ({ labels, from, subject, snippet, content }) =>
          !labels.has('SPAM') &&
          !labels.has('TRASH') &&
          words.every((word) =>
            [from, subject, snippet, content.text ?? '', content.html ?? '']
              .join('\n')
              .toLowerCase()
              .includes(word),
          ),
      ),
      Order.flip(
        Order.mapInput(
          Order.Number,
          (message: SyntheticMessage) => message.internalDate,
        ),
      ),
    );
  };
  const listPage = (params: URLSearchParams) => {
    const query = params.get('q');
    const inbox = query === null ? newestInbox() : searched(query);
    const start = Number(params.get('pageToken') ?? 0);
    const end = start + Number(params.get('maxResults') ?? 100);
    return respond({
      messages: inbox.slice(start, end).map(({ id }) => ({ id, threadId: id })),
      ...(end < inbox.length ? { nextPageToken: String(end) } : {}),
    });
  };
  // Gmail's `format=full` shape: one readable part, or an alternative of the text and HTML parts
  // and the inline images in a related scope, beside an attachment.
  const fullPayload = (message: SyntheticMessage) => {
    const { content } = message;
    // The message's own headers lead its top-level part, as in Gmail's response.
    const top = [
      { name: 'From', value: message.from },
      { name: 'Subject', value: message.subject },
      ...message.headers,
    ];
    const part = (mimeType: string, text: string, partId: string) => ({
      partId,
      mimeType,
      filename: '',
      headers: [
        {
          name: 'Content-Type',
          value: `${mimeType}; charset="${content.charset ?? 'utf8'}"`,
        },
        ...[content.disposition ?? []].flat().map((value) => ({
          name: 'Content-Disposition',
          value,
        })),
      ],
      body: content.separate
        ? {
            size: byteSize(text, content.charset),
            attachmentId: `part-${partId}`,
          }
        : {
            size: byteSize(text, content.charset),
            data: base64Url(text, content.charset),
          },
    });
    if (content.single === true) {
      const single =
        content.html === undefined
          ? part('text/plain', content.text ?? '', '0-0')
          : part('text/html', content.html, '0-1');
      return { ...single, headers: [...top, ...single.headers] };
    }
    const images = (content.images ?? []).map((image, index) => ({
      partId: `1-${index}`,
      mimeType: image.mimeType,
      filename: `image-${index}`,
      headers: [
        { name: 'Content-Type', value: image.mimeType },
        { name: 'Content-ID', value: `<${image.contentId}>` },
        { name: 'Content-Disposition', value: 'inline' },
      ],
      body: {
        size: image.size ?? image.bytes.length,
        attachmentId: `image-${index}`,
      },
    }));
    return {
      mimeType: 'multipart/mixed',
      filename: '',
      headers: top,
      parts: [
        {
          mimeType: 'multipart/related',
          filename: '',
          parts: [
            {
              mimeType: 'multipart/alternative',
              filename: '',
              parts: [
                ...(content.text === undefined
                  ? []
                  : [part('text/plain', content.text, '0-0')]),
                ...(content.html === undefined
                  ? []
                  : [part('text/html', content.html, '0-1')]),
              ],
            },
            ...images,
          ],
        },
        {
          mimeType: 'text/plain',
          filename: 'notes.txt',
          body: { size: notesText.length, attachmentId: 'attached-file' },
        },
        ...(content.attachments ?? []).map((file, index) => ({
          mimeType: file.mimeType,
          filename: file.filename,
          headers: [
            { name: 'Content-Type', value: file.mimeType },
            {
              name: 'Content-Disposition',
              value: file.disposition ?? 'attachment',
            },
          ],
          body: {
            size: file.size ?? file.bytes.length,
            attachmentId: `file-${index}`,
          },
        })),
      ],
    };
  };
  const attachment = (id: string, attachmentId: string) => {
    const content = messages.get(id)?.content;
    if (content === undefined) {
      return notFound();
    }
    if (attachmentId.startsWith('image-')) {
      return imageAttachment(content, attachmentId);
    }
    return attachmentId.startsWith('part-')
      ? partAttachment(content, attachmentId)
      : fileAttachment(content, attachmentId);
  };
  const metadata = (id: string, params: URLSearchParams) => {
    const message = messages.get(id);
    if (message === undefined) {
      return notFound();
    }
    if (params.get('format') === 'full') {
      return respond({
        id: message.id,
        threadId: message.id,
        labelIds: [...message.labels],
        snippet: message.snippet,
        payload: fullPayload(message),
      });
    }
    // The body-free preflight prefetch makes before downloading a body.
    if (params.getAll('metadataHeaders').includes('Content-Type')) {
      const payload = fullPayload(message);
      return respond({
        id: message.id,
        threadId: message.id,
        labelIds: [...message.labels],
        payload: {
          mimeType: payload.mimeType,
          headers:
            'headers' in payload
              ? payload.headers.filter(({ name }) =>
                  params.getAll('metadataHeaders').includes(name),
                )
              : [],
        },
      });
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
    const [, id = '', attachmentId] =
      /^messages\/(?<id>\w+)(?:\/attachments\/(?<part>[\w-]+))?$/u.exec(path) ??
      [];
    if (attachmentId !== undefined) {
      return attachment(id, attachmentId);
    }
    if (id !== '') {
      return metadata(id, params);
    }
    if (path === 'labels') {
      return respond({
        labels: [
          ...systemLabels.map((label) => ({
            id: label,
            name: label,
            type: 'system',
          })),
          ...[...userLabels].map(([label, name]) => ({
            id: label,
            name,
            type: 'user',
          })),
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
  // The message as native code assembles it from verified Draft Asset bytes; undefined when a
  // file's bytes are missing.
  const assemble = (segments: OutgoingSend['segments']) => {
    let raw = '';
    for (const segment of segments) {
      if ('text' in segment) {
        raw += segment.text;
      } else {
        const bytes = assets?.(segment.asset.id, segment.asset.digest);
        if (bytes === undefined) {
          return undefined;
        }
        raw += base64Lines(bytes);
      }
    }
    return raw;
  };
  // Gmail keeps an accepted message in Sent and in history.
  const accept = (raw: string, threadId: string | undefined) => {
    nextId += 1;
    const id = nextId.toString(16);
    const subject =
      /^Subject: (?<subject>.*)$/mu.exec(raw)?.groups?.subject ?? '';
    messages.set(id, {
      id,
      from: address,
      subject,
      snippet: subject,
      internalDate: Date.UTC(2026, 8, 1) + nextId * 60_000,
      labels: new Set(['SENT']),
      content: { text: '' },
      headers: [],
    });
    record('messagesAdded', id);
    sends.push({ raw, id, ...(threadId === undefined ? {} : { threadId }) });
    return id;
  };
  let generation = 0;
  const current = (owner: Readonly<{ address: string; generation: string }>) =>
    owner.address === address && owner.generation === String(generation);
  const remote = createSyntheticRemoteContent(current, () => address);
  const native = {
    gmailRequest: (path, query, owner) => {
      if (owner.signal?.aborted === true) {
        throw new Error('The Gmail request was cancelled.');
      }
      return owner.address === address &&
        owner.generation === String(generation)
        ? readGmail(path, query)
        : rejection('mailbox-invalidated');
    },
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
    gmailSend: async ({ segments, threadId }, owner) => {
      if (!current(owner)) {
        return rejection('mailbox-invalidated');
      }
      const raw = assemble(segments);
      if (raw === undefined) {
        return rejection('attachment-missing');
      }
      const failure = sendFailures.shift();
      if (failure !== undefined && !('lost' in failure)) {
        return 'code' in failure
          ? rejection(failure.code)
          : { status: failure.status, body: failure.body ?? '{}' };
      }
      const id = accept(raw, threadId);
      await Promise.resolve();
      return failure === undefined
        ? {
            status: 200,
            body: JSON.stringify({
              id,
              threadId: threadId ?? id,
              labelIds: ['SENT'],
            }),
          }
        : rejection('delivery-unknown');
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
    openMessageBody: (owner, id) => {
      const code = bodyFailures.shift();
      if (code !== undefined) {
        return rejection(code);
      }
      return current(owner)
        ? Promise.resolve({
            document: bodies.get(bodyKey(owner.address, id)) ?? null,
          })
        : rejection('mailbox-invalidated');
    },
    commitMessageBody: (owner, id, { document, tier, protectedIds }) => {
      if (!current(owner)) {
        return rejection('mailbox-invalidated');
      }
      bodyCommits.push({ id, tier, protectedIds });
      if (refusedBodies.has(id)) {
        return Promise.resolve({ admitted: false });
      }
      const key = bodyKey(owner.address, id);
      bodies.set(key, document);
      if (tier === 'excluded') {
        excludedBodies.add(key);
      } else {
        excludedBodies.delete(key);
      }
      return Promise.resolve({ admitted: true });
    },
    listMessageBodies: (owner, ids) => {
      if (!current(owner)) {
        return rejection('mailbox-invalidated');
      }
      const stored = ids.filter((id) => bodies.has(bodyKey(owner.address, id)));
      return Promise.resolve({
        stored,
        excluded: stored.filter((id) =>
          excludedBodies.has(bodyKey(owner.address, id)),
        ),
      });
    },
    retainMessageBodies: (owner, ids, protectedIds) => {
      bodyRetains.push(protectedIds);
      const code = retainFailures.shift();
      if (code !== undefined) {
        return rejection(code);
      }
      if (!current(owner)) {
        return rejection('mailbox-invalidated');
      }
      if (owner.revision !== (cache?.revision ?? 0)) {
        return rejection('conflict');
      }
      const kept = new Set(ids.map((id) => bodyKey(owner.address, id)));
      for (const key of bodies.keys()) {
        if (!kept.has(key)) {
          bodies.delete(key);
          excludedBodies.delete(key);
        }
      }
      return Promise.resolve(null);
    },
    // Native code decodes the data again and refuses bytes that differ from the declared size.
    saveAttachment: (owner, { name, data, size }) => {
      const code = saveFailures.shift();
      if (code !== undefined) {
        return rejection(code);
      }
      if (!current(owner)) {
        return rejection('mailbox-invalidated');
      }
      const bytes = Base64Url.decode(data);
      if (Result.isFailure(bytes) || bytes.success.length !== size) {
        return rejection('unavailable');
      }
      nextFile += 1;
      const file = `00000000-0000-4000-8000-${String(nextFile).padStart(12, '0')}`;
      savedFiles.set(file, { name, bytes: bytes.success });
      return Promise.resolve({ file });
    },
    discardAttachment: (_owner, file) => {
      savedFiles.delete(file);
      return Promise.resolve(null);
    },
    presentAttachment: (owner, file, action) => {
      const saved = savedFiles.get(file);
      if (!current(owner)) {
        return rejection('mailbox-invalidated');
      }
      if (saved === undefined) {
        return rejection('attachment-missing');
      }
      const code = presentFailures.shift();
      if (code !== undefined) {
        return rejection(code);
      }
      presentations.push({ name: saved.name, action });
      return Promise.resolve(null);
    },
    ...remote.native,
  } satisfies NativeGmailMailbox;

  return {
    native,
    requests,
    commits,
    // Modify requests that reached Gmail, in order.
    modifies,
    // Messages Gmail accepted, in order.
    sends,
    failSend: (...next: readonly SendFailure[]) => {
      sendFailures.push(...next);
    },
    deliver,
    labelsOf: (id: string) => [...(messages.get(id)?.labels ?? [])],
    // A label created in Gmail; its ID never matches its name.
    createLabel: (name: string) => {
      nextLabel += 1;
      const id = `Label_${nextLabel}`;
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
    label: (id: string, label: string) => {
      relabel(id, label, true);
    },
    bodyCommits,
    bodyRetains,
    ...remote.controls,
    // Attachment files saved for this connection, with the name and bytes each was saved with.
    savedFiles,
    presentations,
    failSave: (code: string) => {
      saveFailures.push(code);
    },
    // The system cannot show the next presentation, as without a window or presenter.
    failPresent: (code: string) => {
      presentFailures.push(code);
    },
    // Native admission refuses this message's body, as when it cannot fit.
    refuseBody: (id: string) => {
      refusedBodies.add(id);
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
      bodies.clear();
      // Native code removes the previous connection's files with its cache.
      savedFiles.clear();
      excludedBodies.clear();
      messages.clear();
      userLabels.clear();
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
    failBodyOpen: (code: string) => {
      bodyFailures.push(code);
    },
    failRetain: (code: string) => {
      retainFailures.push(code);
    },
    // The decoded body documents this device holds, by message ID.
    cachedBodies: () =>
      new Map(
        [...bodies]
          .filter(([key]) => key.startsWith(`${address}\n`))
          .map(([key, document]) => [key.slice(address.length + 1), document]),
      ),
  };
}

// A connection native code does not know reaches no Gmail mailbox.
const missing = () => rejection('gmail-unavailable');

// Several controlled Gmail mailboxes behind one native module. Each call reaches only the mailbox
// of the connection it names, as native code routes it; another connection's ID reaches nothing.
export function syntheticConnections(
  mailboxes: Readonly<Record<string, Readonly<{ native: NativeGmailMailbox }>>>,
): NativeGmailMailboxes {
  const of = (connection: string) =>
    Object.hasOwn(mailboxes, connection)
      ? mailboxes[connection]?.native
      : undefined;
  return {
    gmailRequest: (path, query, mailbox) =>
      of(mailbox.connection)?.gmailRequest(path, query, mailbox) ?? missing(),
    gmailModify: (change, mailbox) =>
      of(mailbox.connection)?.gmailModify(change, mailbox) ?? missing(),
    gmailSend: (message, mailbox) =>
      of(mailbox.connection)?.gmailSend(message, mailbox) ?? missing(),
    openMailbox: (connection) => of(connection)?.openMailbox() ?? missing(),
    commitMailbox: (mailbox, revision, document) =>
      of(mailbox.connection)?.commitMailbox(mailbox, revision, document) ??
      missing(),
    openMessageBody: (mailbox, id) =>
      of(mailbox.connection)?.openMessageBody(mailbox, id) ?? missing(),
    commitMessageBody: (mailbox, id, admission) =>
      of(mailbox.connection)?.commitMessageBody(mailbox, id, admission) ??
      missing(),
    listMessageBodies: (mailbox, ids) =>
      of(mailbox.connection)?.listMessageBodies(mailbox, ids) ?? missing(),
    retainMessageBodies: (mailbox, ids, protectedIds) =>
      of(mailbox.connection)?.retainMessageBodies(mailbox, ids, protectedIds) ??
      missing(),
    saveAttachment: (mailbox, attachment) =>
      of(mailbox.connection)?.saveAttachment(mailbox, attachment) ?? missing(),
    discardAttachment: (mailbox, file) =>
      of(mailbox.connection)?.discardAttachment(mailbox, file) ?? missing(),
    presentAttachment: (mailbox, file, action) =>
      of(mailbox.connection)?.presentAttachment(mailbox, file, action) ??
      missing(),
    openRemoteContent: (mailbox, resource) =>
      of(mailbox.connection)?.openRemoteContent(mailbox, resource) ?? missing(),
    fetchRemoteContent: (mailbox, url, request) =>
      of(mailbox.connection)?.fetchRemoteContent(mailbox, url, request) ??
      missing(),
    cancelRemoteContent: (mailbox, session, finished) =>
      of(mailbox.connection)?.cancelRemoteContent(mailbox, session, finished) ??
      missing(),
    commitRemoteContent: (mailbox, resource, admission) =>
      of(mailbox.connection)?.commitRemoteContent(
        mailbox,
        resource,
        admission,
      ) ?? missing(),
  };
}
