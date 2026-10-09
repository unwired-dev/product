import type { Translate } from '@private-email/localization';

import type { ComposerNavigation } from './composer-navigation.ts';
import type {
  AssetSource,
  Draft,
  Drafts,
  PickedFile,
  Recipient,
} from './drafts.ts';
import type { GmailInbox, GmailMessage } from './gmail-inbox.ts';
import type { BodyDocument } from './message-body.ts';
import type { MailboxConnection } from './registration.ts';
import type { Asset, Block, SemanticDocument } from './semantic-document.ts';

import { recipientLabel, recipientsOf } from './drafts.ts';
import { presentation } from './message-body.ts';
import { imageCharacter } from './semantic-document.ts';

// Reply, Reply All and Forward from the reader: a Draft addressed from the received message, in
// the Mailbox Connection that received it. Its quoted correspondence stays apart from the body.

export type ResponseKind = 'reply' | 'replyAll' | 'forward';

// The most earlier message identifiers a reply's References keeps, as RFC 5322 suggests trimming.
const referenceLimit = 20;

const messageIds = (header: string | undefined) =>
  header?.match(/<[^<>\s]+>/gu) ?? [];

// Recipients in order, each address once, without `excluded` addresses.
const distinct = (
  recipients: readonly Recipient[],
  excluded: ReadonlySet<string> = new Set(),
) => {
  const seen = new Set(excluded);
  return recipients.filter(({ address }) => {
    const key = address.toLowerCase();
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
};

// One block per line of text; a span never holds a line break or an image's character.
const blocksOf = (kind: Block['kind'], text: string): Block[] =>
  text
    .replaceAll(imageCharacter, '')
    .split(/\r\n?|\n/u)
    .map((line) => ({ kind, spans: line === '' ? [] : [{ text: line }] }));

const documentOf = ([
  first = { kind: 'paragraph', spans: [] },
  ...rest
]: readonly Block[]): SemanticDocument => [first, ...rest];

// The message's readable text, from its plain alternative or its sanitized HTML.
const correspondence = (document: BodyDocument, kind: Block['kind']) =>
  presentation(document).readable.paragraphs.flatMap((spans, index) => [
    ...(index === 0 ? [] : [{ kind, spans: [] }]),
    ...blocksOf(kind, spans.map(({ text }) => text).join('')),
  ]);

// Who a reply goes to: Reply-To when given, else the sender. A message this mailbox sent is
// answered to its original recipients instead.
const repliedTo = (
  headers: NonNullable<BodyDocument['headers']>,
  self: string,
) => {
  const target = recipientsOf(headers.replyTo ?? '');
  const sender = target.length > 0 ? target : recipientsOf(headers.from ?? '');
  const original = recipientsOf(headers.to ?? '');
  return sender.length > 0 &&
    original.length > 0 &&
    sender.every(({ address }) => address.toLowerCase() === self)
    ? original
    : sender;
};

// What a response is made from: the opened message, sent from `from`. `received` is the shown
// received date; a forward also attaches `attachments`.
type ResponseSource = Readonly<{
  message: Pick<GmailMessage, 'id' | 'threadId' | 'subject' | 'sender'>;
  document: BodyDocument;
  from: string;
  received: string;
  attachments?: readonly PickedFile[];
  // A new importing asset for a file, as the Draft store prepares one.
  prepare: (file: Pick<PickedFile, 'name' | 'type'>) => Asset;
}>;

const senderOf = ({ document, message }: ResponseSource) =>
  recipientsOf(document.headers?.from ?? '')
    .map(recipientLabel)
    .join(', ') || message.sender;

// A forward: no recipients, the forwarded header and text, its inline images and attachments.
function forwarded(t: Translate, source: ResponseSource) {
  const { message, document, received, attachments = [], prepare } = source;
  const headers = document.headers ?? {};
  const images = (document.images?.admitted ?? []).map((image) => ({
    asset: prepare({
      name: `image.${image.mimeType.slice('image/'.length)}`,
      type: image.mimeType,
    }),
    source: {
      kind: 'data',
      uri: `data:${image.mimeType};base64,${image.data}`,
    } satisfies AssetSource,
  }));
  const files = attachments.map((file) => ({
    asset: prepare(file),
    source: file.source,
  }));
  const fields = [
    t('drafts.response.forwardedFrom', { value: senderOf(source) }),
    t('drafts.response.forwardedDate', { value: received }),
    t('drafts.response.forwardedSubject', { value: message.subject }),
    ...(headers.to === undefined
      ? []
      : [t('drafts.response.forwardedTo', { value: headers.to })]),
    ...(headers.cc === undefined
      ? []
      : [t('drafts.response.forwardedCc', { value: headers.cc })]),
  ];
  const quoted = documentOf([
    ...blocksOf('paragraph', t('drafts.response.forwarded')),
    ...fields.flatMap((field) => blocksOf('paragraph', field)),
    { kind: 'paragraph', spans: [] },
    ...correspondence(document, 'paragraph'),
    ...images.map(({ asset }): Block => ({
      kind: 'paragraph',
      spans: [{ text: imageCharacter, image: asset }],
    })),
  ]);
  return {
    edit: (draft: Draft): Draft => ({
      ...draft,
      subject: /^\s*fwd?:/iu.test(message.subject)
        ? message.subject
        : `Fwd: ${message.subject}`,
      quoted,
      response: { kind: 'forward', message: message.id },
      ...(files.length === 0
        ? {}
        : { attachments: files.map(({ asset }) => asset) }),
    }),
    imports: [...files, ...images],
  };
}

// Reply's or Reply All's recipients, each once and, but for a message to oneself alone, without
// the sending address.
const replyRecipients = (
  kind: 'reply' | 'replyAll',
  headers: NonNullable<BodyDocument['headers']>,
  self: string,
) => {
  const target = repliedTo(headers, self);
  if (kind === 'reply') {
    return { to: distinct(target), cc: [] };
  }
  const toSelf =
    target.length > 0 &&
    target.every(({ address }) => address.toLowerCase() === self);
  const to = distinct(
    [...target, ...recipientsOf(headers.to ?? '')],
    toSelf ? new Set() : new Set([self]),
  );
  const cc = distinct(
    recipientsOf(headers.cc ?? ''),
    new Set([self, ...to.map(({ address }) => address.toLowerCase())]),
  );
  return { to, cc };
};

// A reply: its recipients, threading headers and the quoted text after an attribution line.
function replied(
  t: Translate,
  kind: 'reply' | 'replyAll',
  source: ResponseSource,
) {
  const { message, document, from, received } = source;
  const headers = document.headers ?? {};
  const { to, cc } = replyRecipients(kind, headers, from.toLowerCase());
  const [inReplyTo] = messageIds(headers.messageId);
  const references = [
    ...new Set([
      ...messageIds(headers.references),
      ...(inReplyTo === undefined ? [] : [inReplyTo]),
    ]),
  ].slice(-referenceLimit);
  const quoted = documentOf([
    ...blocksOf(
      'paragraph',
      t('drafts.response.wrote', { date: received, sender: senderOf(source) }),
    ),
    ...correspondence(document, 'quote'),
  ]);
  return {
    edit: (draft: Draft): Draft => ({
      ...draft,
      to,
      cc,
      subject: /^\s*re:/iu.test(message.subject)
        ? message.subject
        : `Re: ${message.subject}`,
      quoted,
      response: {
        kind,
        message: message.id,
        thread: message.threadId,
        ...(inReplyTo === undefined ? {} : { inReplyTo }),
        references,
      },
    }),
    imports: [],
  };
}

// The Draft fields of a response, with the assets it holds and where their bytes come from.
export const respond = (
  t: Translate,
  kind: ResponseKind,
  source: ResponseSource,
) => (kind === 'forward' ? forwarded(t, source) : replied(t, kind, source));

// The files a forward attaches: each listed attachment of an opened message in `mailbox`,
// downloaded first. One too large to download, or that cannot be downloaded, is attached as a
// failed asset.
export async function forwardedAttachments(
  inbox: Pick<
    GmailInbox,
    'messageAttachments' | 'downloadAttachment' | 'attachmentFile' | 'subscribe'
  >,
  { mailbox, id }: Readonly<{ mailbox: string; id: string }>,
): Promise<readonly PickedFile[]> {
  const stateOf = (locator: string) =>
    inbox.messageAttachments(id)?.find((each) => each.locator === locator)
      ?.state.kind;
  // A download already running when Forward was chosen is awaited rather than started again.
  const settled = (locator: string) =>
    // oxlint-disable-next-line promise/avoid-new -- Waits for the Inbox store's download state.
    new Promise<void>((resolve) => {
      let unsubscribe: (() => void) | undefined = undefined;
      const check = () => {
        if (stateOf(locator) !== 'downloading') {
          unsubscribe?.();
          resolve();
        }
      };
      unsubscribe = inbox.subscribe(check);
      check();
    });
  return Promise.all(
    (inbox.messageAttachments(id) ?? []).map(
      async ({ locator, name, mimeType, state }): Promise<PickedFile> => {
        if (state.kind === 'oversized') {
          return { name, type: mimeType, source: { kind: 'oversized' } };
        }
        await inbox.downloadAttachment(id, locator);
        await settled(locator);
        const saved = inbox.attachmentFile(id, locator);
        return {
          name,
          type: mimeType,
          source:
            saved === undefined
              ? { kind: 'unavailable' }
              : {
                  kind: 'received',
                  mailbox: {
                    connection: mailbox,
                    address: saved.address,
                    generation: saved.generation,
                  },
                  file: saved.file,
                },
        };
      },
    ),
  );
}

// Starts a reply or forward to an opened message from the reader's own Mailbox Connection, never
// another one, and resolves the new Draft once it holds the response; undefined when the message
// is not ready to answer, the mailbox cannot send, or a later destination was chosen meanwhile.
export async function startResponse(
  {
    navigation,
    drafts,
    inbox,
  }: Readonly<{
    navigation: Pick<ComposerNavigation, 'create'>;
    drafts: Pick<Drafts, 'create' | 'abandon' | 'fill' | 'prepare'>;
    inbox: Pick<
      GmailInbox,
      | 'responseSource'
      | 'messageAttachments'
      | 'downloadAttachment'
      | 'attachmentFile'
      | 'subscribe'
    >;
  }>,
  t: Translate,
  {
    kind,
    mailbox,
    message,
    received,
  }: Readonly<{
    kind: ResponseKind;
    mailbox: Pick<MailboxConnection, 'id' | 'address'>;
    message: Pick<GmailMessage, 'id' | 'threadId' | 'subject' | 'sender'>;
    received: string;
  }>,
) {
  const document = inbox.responseSource(message.id);
  if (document === undefined) {
    return undefined;
  }
  const attachments =
    kind === 'forward'
      ? await forwardedAttachments(inbox, {
          mailbox: mailbox.id,
          id: message.id,
        })
      : [];
  const { edit, imports } = respond(t, kind, {
    message,
    document,
    from: mailbox.address,
    received,
    attachments,
    prepare: drafts.prepare,
  });
  return navigation.create(drafts, mailbox, (id) =>
    drafts.fill(id, edit, imports),
  );
}
