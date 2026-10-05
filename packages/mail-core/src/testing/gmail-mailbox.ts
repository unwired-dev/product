import * as Arr from 'effect/Array';
import * as Base64Url from 'effect/encoding/Base64Url';
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
  readonly content: SyntheticContent;
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
  readonly images?: ReadonlyArray<{
    readonly contentId: string;
    readonly mimeType: string;
    readonly bytes: readonly number[];
    // Declared size when it differs from the bytes, as a truncated download would.
    readonly size?: number;
  }>;
}

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
  // The Bounded Encrypted Body Cache, keyed by address and message ID.
  const bodies = new Map<string, string>();
  const bodyFailures: string[] = [];
  // Each body commit's tier and protected working set, as native admission receives them.
  const bodyCommits: Array<{
    id: string;
    tier: string;
    protectedIds: readonly string[];
  }> = [];
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
  }: {
    readonly from?: string;
    readonly subject?: string;
    readonly snippet?: string;
    readonly unread?: boolean;
    readonly at?: number;
    readonly content?: SyntheticContent;
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
  // Gmail's `format=full` shape: one readable part, or an alternative of the text and HTML parts
  // and the inline images in a related scope, beside an attachment.
  const fullPayload = ({ content }: SyntheticMessage) => {
    const part = (mimeType: string, text: string, partId: string) => ({
      partId,
      mimeType,
      filename: '',
      headers: [
        {
          name: 'Content-Type',
          value: `${mimeType}; charset="${content.charset ?? 'utf8'}"`,
        },
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
      return content.html === undefined
        ? part('text/plain', content.text ?? '', '0-0')
        : part('text/html', content.html, '0-1');
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
          body: { size: 12, attachmentId: 'attached-file' },
        },
      ],
    };
  };
  const attachment = (id: string, attachmentId: string) => {
    const content = messages.get(id)?.content;
    if (content === undefined) {
      return notFound();
    }
    return attachmentId.startsWith('image-')
      ? imageAttachment(content, attachmentId)
      : partAttachment(content, attachmentId);
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
              ? payload.headers.filter(({ name }) => name === 'Content-Type')
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
    return path === 'history' ? historyPage(params) : notFound();
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
  const current = (owner: Readonly<{ address: string; generation: string }>) =>
    owner.address === address && owner.generation === String(generation);
  const native = {
    gmailRequest: (path, query, owner) =>
      owner.address === address && owner.generation === String(generation)
        ? readGmail(path, query)
        : rejection('mailbox-invalidated'),
    openMailbox: () => {
      const code = openFailures.shift();
      return code === undefined
        ? Promise.resolve({
            revision: cache?.revision ?? 0,
            address,
            generation: String(generation),
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
      return Promise.resolve({ ...cache, generation: String(generation) });
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
      bodies.set(bodyKey(owner.address, id), document);
      return Promise.resolve({ admitted: true });
    },
    listMessageBodies: (owner, ids) =>
      current(owner)
        ? Promise.resolve({
            stored: ids.filter((id) => bodies.has(bodyKey(owner.address, id))),
          })
        : rejection('mailbox-invalidated'),
    retainMessageBodies: (owner, ids) => {
      if (!current(owner)) {
        return rejection('mailbox-invalidated');
      }
      const kept = new Set(ids.map((id) => bodyKey(owner.address, id)));
      for (const key of bodies.keys()) {
        if (!kept.has(key)) {
          bodies.delete(key);
        }
      }
      return Promise.resolve(null);
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
    label: (id: string, label: string) => {
      relabel(id, label, true);
    },
    bodyCommits,
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
    failBodyOpen: (code: string) => {
      bodyFailures.push(code);
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
