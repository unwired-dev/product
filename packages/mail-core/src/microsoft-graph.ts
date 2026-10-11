import * as DateTime from 'effect/DateTime';
import * as Base64 from 'effect/encoding/Base64';
import * as Base64Url from 'effect/encoding/Base64Url';
import * as Option from 'effect/Option';
import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';

import type { GmailPart } from './message-body.ts';

// Microsoft Graph reads for one Outlook.com or Microsoft 365 mailbox. Native code attaches the
// mailbox's token and refuses any URL outside the signed-in person's own mail; this module chooses
// the requests and turns Graph's JSON into Inbox messages and the MIME part tree bodies use.
const graphRoot = 'https://graph.microsoft.com/v1.0';

const listed =
  'id,conversationId,receivedDateTime,subject,bodyPreview,from,isRead';

// The newest Inbox messages, newest first.
export const graphInbox = (limit: number) =>
  `${graphRoot}/me/mailFolders/inbox/messages?$select=${listed}&$orderby=receivedDateTime%20desc&$top=${limit}`;

// A full delta round over the Inbox; its last page links to the changes after it.
export const graphInboxDelta = `${graphRoot}/me/mailFolders/inbox/messages/delta?$select=${listed}&$orderby=receivedDateTime%20desc`;

export const graphInboxMessage = (id: string) =>
  `${graphRoot}/me/mailFolders/inbox/messages/${id}?$select=${listed}`;

export const graphMessage = (id: string) =>
  `${graphRoot}/me/messages/${id}?$select=body,from,toRecipients,ccRecipients,replyTo,internetMessageId,internetMessageHeaders,hasAttachments`;

export const graphAttachments = (id: string) =>
  `${graphRoot}/me/messages/${id}/attachments?$select=id,name,contentType,size,isInline,contentId`;

export const graphAttachment = (id: string, attachment: string) =>
  `${graphRoot}/me/messages/${id}/attachments/${attachment}`;

// Graph's message and attachment IDs are URL-safe base64 text.
export const GraphId = Schema.String.check(
  Schema.isPattern(/^[\w=-]{1,512}$/u),
);

// A continuation of an Inbox delta round, as Graph returns it.
export const GraphDeltaLink = Schema.String.check(
  Schema.isPattern(
    /^https:\/\/graph\.microsoft\.com\/v1\.0\/me\/mail[Ff]olders(?:\/[\w=-]+|\('[\w=-]+'\))\/messages\/delta\?[^#\s]+$/u,
  ),
);

const GraphInboxLink = Schema.String.check(
  Schema.isPattern(
    /^https:\/\/graph\.microsoft\.com\/v1\.0\/me\/mail[Ff]olders(?:\/[\w=-]+|\('[\w=-]+'\))\/messages\?[^#\s]+$/u,
  ),
);
const GraphAttachmentsLink = Schema.String.check(
  Schema.isPattern(
    /^https:\/\/graph\.microsoft\.com\/v1\.0\/me\/messages\/[\w=-]+\/attachments\?[^#\s]+$/u,
  ),
);

const json = <S extends Schema.Top>(schema: S) =>
  Schema.decodeUnknownEffect(Schema.fromJsonString(schema));

const Text = Schema.optionalKey(Schema.NullOr(Schema.String));
const RecipientSchema = Schema.Struct({
  emailAddress: Schema.Struct({ name: Text, address: Text }),
});
type Recipient = typeof RecipientSchema.Type;

const GraphListedSchema = Schema.Struct({
  id: GraphId,
  conversationId: Text,
  receivedDateTime: Schema.String.check(
    Schema.makeFilter((value) => Option.isSome(DateTime.make(value))),
  ),
  subject: Text,
  bodyPreview: Text,
  isRead: Schema.optionalKey(Schema.Boolean),
  from: Schema.optionalKey(Schema.NullOr(RecipientSchema)),
});
type GraphListed = typeof GraphListedSchema.Type;

export const decodeGraphListed = json(GraphListedSchema);

export const decodeGraphInbox = json(
  Schema.Struct({
    value: Schema.Array(GraphListedSchema),
    '@odata.nextLink': Schema.optionalKey(GraphInboxLink),
  }),
);

const GraphDeltaPageSchema = Schema.Struct({
  // Delta may repeat an ID or supply only changed properties. Read its current Inbox metadata
  // separately instead of inferring ordering or replacing absent fields with empty values.
  value: Schema.Array(Schema.Struct({ id: GraphId })),
  '@odata.nextLink': Schema.optionalKey(GraphDeltaLink),
  '@odata.deltaLink': Schema.optionalKey(GraphDeltaLink),
});
export const decodeGraphDelta = json(GraphDeltaPageSchema);

const GraphFullSchema = Schema.Struct({
  id: GraphId,
  body: Schema.Struct({
    contentType: Schema.Literals(['html', 'text']),
    content: Schema.String,
  }),
  from: Schema.optionalKey(Schema.NullOr(RecipientSchema)),
  toRecipients: Schema.optionalKey(Schema.Array(RecipientSchema)),
  ccRecipients: Schema.optionalKey(Schema.Array(RecipientSchema)),
  replyTo: Schema.optionalKey(Schema.Array(RecipientSchema)),
  internetMessageId: Text,
  internetMessageHeaders: Schema.optionalKey(
    Schema.Array(Schema.Struct({ name: Schema.String, value: Schema.String })),
  ),
  hasAttachments: Schema.optionalKey(Schema.Boolean),
});
type GraphFull = typeof GraphFullSchema.Type;
export const decodeGraphFull = json(GraphFullSchema);

const GraphAttachmentInfoSchema = Schema.Struct({
  '@odata.type': Schema.optionalKey(Schema.String),
  id: GraphId,
  name: Text,
  contentType: Text,
  size: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  isInline: Schema.optionalKey(Schema.Boolean),
  contentId: Text,
});
export type GraphAttachmentInfo = typeof GraphAttachmentInfoSchema.Type;

// Only file attachments carry downloadable bytes; attached Outlook items and cloud links do not.
export const decodeGraphAttachments = json(
  Schema.Struct({
    value: Schema.Array(GraphAttachmentInfoSchema),
    '@odata.nextLink': Schema.optionalKey(GraphAttachmentsLink),
  }),
);
export const fileAttachments = (attachments: readonly GraphAttachmentInfo[]) =>
  attachments.filter(
    (attachment) =>
      (attachment['@odata.type'] ?? '#microsoft.graph.fileAttachment') ===
      '#microsoft.graph.fileAttachment',
  );

export const decodeGraphFile = json(
  Schema.Struct({ contentBytes: Schema.String, contentId: Text }),
);

// Graph's standard base64 as the base64url data and exact size the body pipeline reads.
export const fileData = (contentBytes: string) => {
  const bytes = Base64.decode(contentBytes);
  return Result.isFailure(bytes)
    ? undefined
    : { data: Base64Url.encode(bytes.success), size: bytes.success.length };
};

// The Inbox's view of a listed Graph message. Graph has no labels to organize with here, so none
// are kept and the Inbox offers no organizing actions.
export const listedMessage = (message: GraphListed) => {
  const sender = message.from?.emailAddress;
  const address = sender?.address?.trim() ?? '';
  const name = sender?.name?.trim() ?? '';
  return {
    id: message.id,
    threadId:
      message.conversationId === ''
        ? message.id
        : (message.conversationId ?? message.id),
    sender: name === '' ? address : name,
    address,
    subject: message.subject ?? '',
    preview: message.bodyPreview ?? '',
    receivedAt: DateTime.formatIso(
      Option.getOrThrow(DateTime.make(message.receivedDateTime)),
    ),
    unread: message.isRead === false,
  };
};

// A delta page's distinct changed identities, including removals.
export const deltaIds = (
  items: (typeof GraphDeltaPageSchema.Type)['value'],
) => [...new Set(items.map(({ id }) => id))];

const oneLine = (value: string) => value.replaceAll(/[\r\n]+/gu, ' ').trim();

const mailbox = ({ emailAddress: { name, address } }: Recipient) => {
  const plain = oneLine(address ?? '');
  const display = oneLine(name ?? '');
  if (plain === '') {
    return undefined;
  }
  return display === '' || display === plain
    ? plain
    : `"${display.replaceAll(/["\\]/gu, String.raw`\$&`)}" <${plain}>`;
};

const mailboxes = (recipients: readonly Recipient[] | undefined) =>
  (recipients ?? [])
    .flatMap((recipient) => mailbox(recipient) ?? [])
    .join(', ');

// Reply, Reply All and Forward read these; content headers never cross into the part tree, where
// they would contradict its own structure.
const responseHeaders = (message: GraphFull) => {
  const transport = (name: string) =>
    message.internetMessageHeaders?.find(
      (candidate) => candidate.name.toLowerCase() === name,
    )?.value;
  return (
    [
      [
        'From',
        message.from === undefined || message.from === null
          ? undefined
          : mailbox(message.from),
      ],
      ['Reply-To', mailboxes(message.replyTo)],
      ['To', mailboxes(message.toRecipients)],
      ['Cc', mailboxes(message.ccRecipients)],
      ['Date', transport('date')],
      ['Message-ID', message.internetMessageId ?? transport('message-id')],
      ['In-Reply-To', transport('in-reply-to')],
      ['References', transport('references')],
    ] as const
  ).flatMap(([name, value]) =>
    value === undefined || value === null || oneLine(value) === ''
      ? []
      : [{ name, value: oneLine(value) }],
  );
};

const mediaType = (contentType: string | null | undefined) =>
  /^[\w.+-]+\/[\w.+-]+/u.exec((contentType ?? '').trim().toLowerCase())?.[0] ??
  'application/octet-stream';

const attachmentPart = (attachment: GraphAttachmentInfo): GmailPart => {
  const type = mediaType(attachment.contentType);
  return {
    mimeType: type,
    filename: attachment.name ?? '',
    headers: [
      { name: 'Content-Type', value: type },
      {
        name: 'Content-Disposition',
        value: attachment.isInline === true ? 'inline' : 'attachment',
      },
      ...(attachment.contentId === undefined || attachment.contentId === null
        ? []
        : [
            { name: 'Content-ID', value: `<${oneLine(attachment.contentId)}>` },
          ]),
    ],
    // Graph's attachment size is approximate; downloaded bytes report their own exact size.
    body: { attachmentId: attachment.id, size: attachment.size },
  };
};

// A Graph message as the MIME tree Gmail would return: its one decoded body, then inline parts in
// the related scope and other attachments beside it. Its shape depends only on the attachment
// list, so a part's locator is the same whether or not inline images were read.
export function graphPayload(
  message: GraphFull,
  attachments: readonly GraphAttachmentInfo[],
): GmailPart {
  const type = message.body.contentType === 'html' ? 'text/html' : 'text/plain';
  const bytes = new TextEncoder().encode(message.body.content);
  const content: GmailPart = {
    mimeType: type,
    headers: [{ name: 'Content-Type', value: `${type}; charset=utf-8` }],
    body: { data: Base64Url.encode(bytes), size: bytes.length },
  };
  const headers = responseHeaders(message);
  if (attachments.length === 0) {
    return { ...content, headers: [...headers, ...(content.headers ?? [])] };
  }
  return {
    mimeType: 'multipart/mixed',
    headers: [...headers, { name: 'Content-Type', value: 'multipart/mixed' }],
    parts: [
      {
        mimeType: 'multipart/related',
        headers: [{ name: 'Content-Type', value: 'multipart/related' }],
        parts: [
          content,
          ...attachments
            .filter(({ isInline }) => isInline === true)
            .map(attachmentPart),
        ],
      },
      ...attachments
        .filter(({ isInline }) => isInline !== true)
        .map(attachmentPart),
    ],
  };
}
