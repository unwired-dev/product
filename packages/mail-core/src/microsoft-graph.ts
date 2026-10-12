import * as DateTime from 'effect/DateTime';
import * as Base64 from 'effect/encoding/Base64';
import * as Base64Url from 'effect/encoding/Base64Url';
import * as Option from 'effect/Option';
import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';

import type { GmailAction } from './gmail-actions.ts';
import type { GmailPart } from './message-body.ts';

import { GraphId } from './mailbox-message.ts';

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

// Where a message is and whether it was read, which organizing reads back.
export const graphPlacement = (id: string) =>
  `${graphRoot}/me/messages/${id}?$select=id,parentFolderId,isRead`;

// A well-known folder's own ID, which a message's parentFolderId names.
export const graphWellKnownFolder = (name: WellKnownFolder) =>
  `${graphRoot}/me/mailFolders/${name}?$select=id`;

// The mailbox's top-level folders and each folder's own, which Move to offers apart from the
// well-known ones; a page names whether a folder has folders of its own.
const folderFields = '$select=id,displayName,childFolderCount&$top=100';
export const graphFolders = `${graphRoot}/me/mailFolders?${folderFields}`;
export const graphChildFolders = (id: string) =>
  `${graphRoot}/me/mailFolders/${id}/childFolders?${folderFields}`;

// Graph's own search of every folder, ordered by sent time; a quote inside the query is escaped.
export const graphSearch = (query: string, limit: number) =>
  `${graphRoot}/me/messages?$search=${encodeURIComponent(`"${query.replaceAll(/["\\]/gu, String.raw`\$&`)}"`)}&$select=${listed},parentFolderId&$top=${limit}`;

// Sent Items' copies of a message this device sent, by the Message-ID it wrote; a quote inside the
// identifier is doubled, as OData requires.
export const graphSentCopies = (messageId: string) =>
  `${graphRoot}/me/mailFolders/sentitems/messages?$filter=${encodeURIComponent(`internetMessageId eq '<${messageId.replaceAll("'", "''")}>'`)}&$select=id&$top=2`;

// Folders whose role the Inbox knows, and those Move to never offers.
export const wellKnownFolders = [
  'inbox',
  'archive',
  'deleteditems',
  'junkemail',
  'drafts',
  'sentitems',
  'outbox',
] as const;
export type WellKnownFolder = (typeof wellKnownFolders)[number];

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
const GraphSearchLink = Schema.String.check(
  Schema.isPattern(
    /^https:\/\/graph\.microsoft\.com\/v1\.0\/me\/messages\?[^#\s]+$/u,
  ),
);
export const isGraphSearchLink = Schema.is(GraphSearchLink);
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

// A message lives in exactly one folder. Organizing reads it with Gmail's label model: its folder's
// role, or the folder itself, and its read state. Archive remains distinct so another folder
// cannot falsely confirm an interrupted archive.
const roleLabels: Partial<Record<WellKnownFolder, string>> = {
  inbox: 'INBOX',
  archive: 'ARCHIVE',
  deleteditems: 'TRASH',
  junkemail: 'SPAM',
};
// Well-known folders by their IDs in one mailbox.
export type FolderRoles = ReadonlyMap<string, WellKnownFolder>;
export const graphLabels = (
  folder: string | undefined,
  isRead: boolean | undefined,
  roles: FolderRoles,
) => {
  const role = folder === undefined ? undefined : roles.get(folder);
  const place = role === undefined ? folder : roleLabels[role];
  return [
    ...(place === undefined ? [] : [place]),
    ...(isRead === false ? ['UNREAD'] : []),
  ];
};

// The one Graph change an organizing action makes. Star and Gmail labels have none for Microsoft
// mail, which offers neither.
export type GraphChange = Readonly<{ read: boolean } | { folder: string }>;
// The well-known folder each removal from the Inbox, or Undo, moves a message to.
const folderMoves: Partial<Record<GmailAction['kind'], WellKnownFolder>> = {
  archive: 'archive',
  trash: 'deleteditems',
  spam: 'junkemail',
  restore: 'inbox',
};
export const graphUnavailableActions = (
  roles: FolderRoles | undefined,
): ReadonlyArray<GmailAction['kind']> => {
  const available = [...(roles?.values() ?? [])];
  return (['archive', 'trash', 'spam'] as const).filter(
    (kind) => !available.some((role) => role === folderMoves[kind]),
  );
};
export const graphChange = (action: GmailAction): GraphChange | undefined => {
  if (action.kind === 'read' || action.kind === 'unread') {
    return { read: action.kind === 'read' };
  }
  const [chosen] = action.add;
  const folder = action.kind === 'move' ? chosen : folderMoves[action.kind];
  return folder === undefined ? undefined : { folder };
};

const GraphPlacementSchema = Schema.Struct({
  id: GraphId,
  parentFolderId: GraphId,
  isRead: Schema.Boolean,
});
// A message after a change, or as organizing reads it back.
export const decodeGraphPlacement = json(GraphPlacementSchema);
export const decodeGraphFolder = json(Schema.Struct({ id: GraphId }));
export const decodeGraphFolders = json(
  Schema.Struct({
    value: Schema.Array(
      Schema.Struct({
        id: GraphId,
        displayName: Schema.String,
        childFolderCount: Schema.optionalKey(Schema.Int),
      }),
    ),
    // A further page; Move to lists only the first.
    '@odata.nextLink': Schema.optionalKey(Schema.String),
  }),
);
export const decodeGraphCopies = json(
  Schema.Struct({
    value: Schema.Array(Schema.Struct({ id: GraphId })),
    '@odata.nextLink': Schema.optionalKey(Schema.String),
  }),
);
export const decodeGraphSearch = json(
  Schema.Struct({
    value: Schema.Array(
      Schema.Struct({
        ...GraphListedSchema.fields,
        parentFolderId: Schema.optionalKey(GraphId),
      }),
    ),
    '@odata.nextLink': Schema.optionalKey(GraphSearchLink),
  }),
);

// The Inbox's view of a listed Graph message; an Inbox listing names no folder, so its labels say
// Inbox, and a search result's say where it is.
export const listedMessage = (
  message: GraphListed,
  labels = ['INBOX', ...(message.isRead === false ? ['UNREAD'] : [])],
) => {
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
    labels,
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
