import * as DateTime from 'effect/DateTime';
import * as Base64 from 'effect/encoding/Base64';
import * as Base64Url from 'effect/encoding/Base64Url';
import * as Option from 'effect/Option';
import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';
import * as SchemaTransformation from 'effect/SchemaTransformation';

import type { GmailAction } from './gmail-actions.ts';
import type { GmailPart } from './message-body.ts';

import { GraphId } from './mailbox-message.ts';
import { messageCalendar } from './message-body.ts';

// Microsoft Graph reads for one Outlook.com or Microsoft 365 mailbox. Native code attaches the
// mailbox's token and refuses any URL outside the signed-in person's own mail; this module chooses
// the requests and turns Graph's JSON into Inbox messages and the MIME part tree bodies use.
const graphRoot = 'https://graph.microsoft.com/v1.0';

const listed =
  'id,conversationId,receivedDateTime,subject,bodyPreview,from,isRead,categories';

// A folder's newest messages, or older mail for a cache refill, newest first.
export const graphMessages = (view: string, limit: number, until?: string) =>
  `${graphRoot}/me/mailFolders/${graphFolder(view)}/messages?$select=${listed}&$orderby=receivedDateTime%20desc&$top=${limit}${until === undefined ? '' : `&$filter=receivedDateTime%20le%20${encodeURIComponent(until)}`}`;

// A full delta round over a folder; its last page links to the changes after it.
export const graphDelta = (view: string) =>
  `${graphRoot}/me/mailFolders/${graphFolder(view)}/messages/delta?$select=${listed}&$orderby=receivedDateTime%20desc`;

export const graphFolderMessage = (view: string, id: string) =>
  `${graphRoot}/me/mailFolders/${graphFolder(view)}/messages/${id}?$select=${listed},parentFolderId`;

export const graphMessage = (id: string) =>
  `${graphRoot}/me/messages/${id}?$select=body,from,toRecipients,ccRecipients,replyTo,internetMessageId,internetMessageHeaders,hasAttachments`;

// A message's MIME, which alone carries a meeting request's calendar.
export const graphMime = (id: string) =>
  `${graphRoot}/me/messages/${id}/$value`;

// Content-ID belongs to file attachments, so Graph refuses it unqualified in a list's $select.
export const graphAttachments = (id: string) =>
  `${graphRoot}/me/messages/${id}/attachments?$select=id,name,contentType,size,isInline,microsoft.graph.fileAttachment/contentId`;

export const graphAttachment = (id: string, attachment: string) =>
  `${graphRoot}/me/messages/${id}/attachments/${attachment}`;

// Where a message is, whether it was read and its categories, which organizing reads back.
export const graphPlacement = (id: string) =>
  `${graphRoot}/me/messages/${id}?$select=id,parentFolderId,isRead,categories`;

// A well-known folder's own ID, which a message's parentFolderId names.
// The mailbox's automatic replies, Outlook's Out of Office, which `MailboxSettings.Read` reads.
export const graphAutomaticReplies = `${graphRoot}/me/mailboxSettings/automaticRepliesSetting`;
// The mailbox's Outlook category list, which `MailboxSettings.Read` also reads.
export const graphMasterCategories = `${graphRoot}/me/outlook/masterCategories`;

export const graphWellKnownFolder = (name: WellKnownFolder) =>
  `${graphRoot}/me/mailFolders/${name}?$select=id`;

// How many messages a folder holds, for history progress.
export const graphFolderTotal = (view: string) =>
  `${graphRoot}/me/mailFolders/${graphFolder(view)}?$select=totalItemCount`;

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

// A continuation of a folder's listing, as Graph returns it.
export const GraphInboxLink = Schema.String.check(
  Schema.isPattern(
    /^https:\/\/graph\.microsoft\.com\/v1\.0\/me\/mail[Ff]olders(?:\/[\w=-]+|\('[\w=-]+'\))\/messages\?[^#\s]+$/u,
  ),
);
// A folder list, the mailbox's or a folder's own, or its continuation.
export const GraphFoldersLink = Schema.String.check(
  Schema.isPattern(
    /^https:\/\/graph\.microsoft\.com\/v1\.0\/me\/mail[Ff]olders(?:(?:\/[\w=-]+|\('[\w=-]+'\))\/childFolders)?\?[^#\s]+$/u,
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
  categories: Schema.optionalKey(Schema.Array(Schema.String)),
});
type GraphListed = typeof GraphListedSchema.Type;

// A delta change as Graph has it now. Graph reads a message by its ID wherever it is, so the
// folder it names says whether it is still in the folder whose delta named it.
export const decodeGraphListed = json(
  Schema.Struct({ ...GraphListedSchema.fields, parentFolderId: GraphId }),
);

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
  '@odata.type': Schema.optionalKey(Schema.String),
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
  sentitems: 'SENT',
  archive: 'ARCHIVE',
  deleteditems: 'TRASH',
  junkemail: 'SPAM',
  drafts: 'DRAFT',
  outbox: 'OUTBOX',
};
// The Graph folder a view lists: a well-known folder by its role's label, or a folder by its ID.
function graphFolder(view: string) {
  return wellKnownFolders.find((name) => roleLabels[name] === view) ?? view;
}
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

// An Outlook category is a message label of its own: its name in base64url after a prefix that
// neither a role label nor a Graph folder ID has, so it never names a folder.
const categoryPrefix = 'CATEGORY_';
const categoryLabel = (name: string) =>
  `${categoryPrefix}${Base64Url.encode(name)}`;
// A name longer than Outlook allows stays on the message in Graph, unlisted.
export const categoryLabels = (names: readonly string[] = []) =>
  names.filter((name) => name.length <= 255).map(categoryLabel);
// A label's category name, only from the one label that name has.
const categoryName = (label: string) => {
  const name = label.startsWith(categoryPrefix)
    ? Result.getOrUndefined(
        Base64Url.decodeString(label.slice(categoryPrefix.length)),
      )
    : undefined;
  return name !== undefined && categoryLabel(name) === label ? name : undefined;
};
// A category name native code writes: one line of at most 255 characters, as Outlook allows.
const writableName = (name: string | undefined): name is string =>
  name !== undefined &&
  name !== '' &&
  name.length <= 255 &&
  !/[\p{Cc}\u2028\u2029]/u.test(name);
const categoryNames = (labels: readonly string[]) => {
  const names = labels.map(categoryName);
  return names.every(writableName) ? names : undefined;
};

// The categories a label or unlabel action assigns or removes.
export type CategoryChange = Readonly<{
  add: readonly string[];
  remove: readonly string[];
}>;
// A label or unlabel action's category change, or none for any other action.
export const categoryChange = (
  action: GmailAction,
): CategoryChange | undefined => {
  if (action.kind !== 'label' && action.kind !== 'unlabel') {
    return undefined;
  }
  const add = categoryNames(action.add);
  const remove = categoryNames(action.remove);
  return add === undefined ||
    remove === undefined ||
    add.length + remove.length === 0
    ? undefined
    : { add, remove };
};
// A message's categories after a change, keeping every other category as Graph has it now, or
// none when the list holds a name that cannot be written back.
export const changedCategories = (
  current: readonly string[],
  { add, remove }: CategoryChange,
) => {
  const changed = [
    ...current.filter((name) => !remove.includes(name)),
    ...add.filter((name) => !current.includes(name)),
  ];
  return changed.every(writableName) ? changed : undefined;
};

// The one Graph change an organizing action makes. Star has none for Microsoft mail, which doesn't
// offer it, and a category change sets the message's whole category list.
export type GraphChange = Readonly<
  { read: boolean } | { folder: string } | { categories: readonly string[] }
>;
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
  // A category is never a folder to move to.
  return folder === undefined || folder.startsWith(categoryPrefix)
    ? undefined
    : { folder };
};

const GraphPlacementSchema = Schema.Struct({
  id: GraphId,
  parentFolderId: GraphId,
  isRead: Schema.Boolean,
  // Graph always reports them, so a reply without them is not trusted to overwrite them.
  categories: Schema.Array(Schema.String),
});
// A message after a change, or as organizing reads it back.
export const decodeGraphPlacement = json(GraphPlacementSchema);
export const decodeGraphFolder = json(Schema.Struct({ id: GraphId }));

// Graph's date and time in the time zone it names; nothing is converted.
const GraphZonedTime = Schema.Struct({
  dateTime: Schema.String.check(
    Schema.isPattern(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?$/u),
    // A real calendar date and clock time: read as UTC, it must come back unchanged.
    Schema.makeFilter((value) =>
      Option.exists(
        DateTime.make(`${value.slice(0, 19)}Z`),
        (time) => DateTime.formatIso(time).slice(0, 19) === value.slice(0, 19),
      ),
    ),
  ),
  timeZone: Schema.String,
});
// One of Graph's enumeration values, in any letter case, as the documented spelling.
const graphEnum = <const L extends readonly [string, ...string[]]>(values: L) =>
  Schema.String.pipe(
    Schema.decodeTo(
      Schema.Literals(values),
      SchemaTransformation.transform({
        decode: (value) =>
          (values.find(
            (known) => known.toLowerCase() === value.toLowerCase(),
          ) ?? value) as L[number],
        encode: (value) => value,
      }),
    ),
  );
// Automatic replies as Graph stores them: a field Graph leaves out stays out.
const GraphAutomaticRepliesSchema = Schema.Struct({
  status: graphEnum(['disabled', 'alwaysEnabled', 'scheduled']),
  externalAudience: Schema.optionalKey(
    graphEnum(['none', 'contactsOnly', 'all']),
  ),
  internalReplyMessage: Schema.optionalKey(Schema.String),
  externalReplyMessage: Schema.optionalKey(Schema.String),
  scheduledStartDateTime: Schema.optionalKey(GraphZonedTime),
  scheduledEndDateTime: Schema.optionalKey(GraphZonedTime),
});
export type GraphAutomaticReplies = typeof GraphAutomaticRepliesSchema.Type;
export const decodeGraphAutomaticReplies = json(GraphAutomaticRepliesSchema);
// A change to the automatic replies: each named field takes its value, and Graph keeps the others.
export type GraphAutomaticRepliesChange = Partial<GraphAutomaticReplies>;
// Graph's answer to a mailbox settings update names the automatic replies as they are stored now.
export const decodeSavedAutomaticReplies = json(
  Schema.Struct({ automaticRepliesSetting: GraphAutomaticRepliesSchema }),
);
// The category list as Graph stores it: each name with its colour preset, which each Outlook
// client maps to a colour of its own.
const GraphCategoriesSchema = Schema.Struct({
  value: Schema.Array(
    Schema.Struct({
      displayName: Schema.String,
      color: graphEnum([
        'none',
        'preset0',
        'preset1',
        'preset2',
        'preset3',
        'preset4',
        'preset5',
        'preset6',
        'preset7',
        'preset8',
        'preset9',
        'preset10',
        'preset11',
        'preset12',
        'preset13',
        'preset14',
        'preset15',
        'preset16',
        'preset17',
        'preset18',
        'preset19',
        'preset20',
        'preset21',
        'preset22',
        'preset23',
        'preset24',
      ]),
    }),
  ),
});
export type GraphCategory =
  (typeof GraphCategoriesSchema.Type)['value'][number];
export const decodeGraphCategories = json(GraphCategoriesSchema);
export const decodeGraphTotal = json(
  Schema.Struct({
    totalItemCount: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  }),
);
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
  labels = [
    'INBOX',
    ...(message.isRead === false ? ['UNREAD'] : []),
    ...categoryLabels(message.categories),
  ],
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

// Reply, Reply All, Forward and Unsubscribe read these; content headers never cross into the part tree, where
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
      ['List-Id', transport('list-id')],
      ['List-Unsubscribe', transport('list-unsubscribe')],
      ['List-Unsubscribe-Post', transport('list-unsubscribe-post')],
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

// The part that stands for a meeting message's calendar, which only its MIME carries.
export const graphCalendar = messageCalendar;
// The most attachment bytes a meeting message's MIME is read with for its calendar.
const calendarMessageLimit = 4 * 1024 * 1024;

// Outlook files a meeting request or cancellation as an event message, keeping no calendar file;
// a response to the person's own meeting is an event message response.
const meetingTypes = new Set([
  '#microsoft.graph.eventMessageRequest',
  '#microsoft.graph.eventMessage',
]);
const calendarPart = (
  message: GraphFull,
  attachments: readonly GraphAttachmentInfo[],
): readonly GmailPart[] =>
  meetingTypes.has(message['@odata.type'] ?? '') &&
  attachments.reduce((total, { size }) => total + size, 0) <=
    calendarMessageLimit
    ? [
        {
          mimeType: 'text/calendar',
          headers: [
            { name: 'Content-Type', value: 'text/calendar; charset=utf-8' },
          ],
          body: { attachmentId: graphCalendar, size: 0 },
        },
      ]
    : [];

// A Graph message as the MIME tree Gmail would return: its one decoded body, then inline parts in
// the related scope and other attachments beside it, and a meeting message's calendar last. Its
// shape depends only on the attachment list and message type, so a part's locator is the same
// whether or not inline images were read.
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
  const calendar = calendarPart(message, attachments);
  if (attachments.length === 0 && calendar.length === 0) {
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
      ...calendar,
    ],
  };
}
