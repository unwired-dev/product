import * as Arr from 'effect/Array';
import * as DateTime from 'effect/DateTime';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Schema from 'effect/Schema';

import type { GmailLabel } from './gmail-actions.ts';
import type {
  GmailMessage,
  MailboxDocument,
  MailboxHistory,
  MailboxScope,
  PendingAction,
} from './mailbox-document.ts';
import type { GmailInvalidPage, NativeGmailRequests } from './mailbox-read.ts';
import type { GmailNotFound } from './mailbox-read.ts';
import type { GmailPart } from './message-body.ts';
import type { OutgoingSend } from './outgoing-message.ts';
import type {
  ProviderPayload,
  ProviderReader,
  ReaderViews,
  ViewEntry,
} from './provider-reader.ts';

import { logNote } from './diagnostics.ts';
import {
  allMail,
  gmailArchive,
  GmailLabelSchema,
  inInbox,
  inView,
  labelsOf,
} from './gmail-actions.ts';
import {
  foldDue,
  foldStep,
  historyPageSize,
  listed as listedHistory,
  recorded,
  restarted,
  segmentName,
  segmentNames,
} from './gmail-history.ts';
import {
  cacheLimit,
  GmailId,
  HistoryId,
  merge,
  newestFirst,
} from './mailbox-document.ts';
import { providerRead, providerWrite, SyncFailure } from './mailbox-read.ts';
import {
  decodeAttachment,
  decodeFullMessage,
  unescapeHtml,
} from './message-body.ts';

export const pageSize = 50;

// The newest Sent messages read for a message whose handoff had no answer.
const sentPageSize = 20;

const json = <S extends Schema.Top>(schema: S) =>
  Schema.decodeUnknownEffect(Schema.fromJsonString(schema));

const decodeProfile = json(
  Schema.Struct({
    emailAddress: Schema.String,
    historyId: HistoryId,
    messagesTotal: Schema.optionalKey(Schema.Int),
  }),
);

const decodeList = json(
  Schema.Struct({
    messages: Schema.optionalKey(Schema.Array(Schema.Struct({ id: GmailId }))),
    nextPageToken: Schema.optionalKey(Schema.String),
  }),
);

const decodeMetadata = json(
  Schema.Struct({
    id: GmailId,
    threadId: Schema.String,
    labelIds: Schema.optionalKey(Schema.Array(Schema.String)),
    snippet: Schema.optionalKey(Schema.String),
    internalDate: Schema.String.check(Schema.isPattern(/^\d{1,15}$/u)),
    payload: Schema.optionalKey(
      Schema.Struct({
        headers: Schema.optionalKey(
          Schema.Array(
            Schema.Struct({ name: Schema.String, value: Schema.String }),
          ),
        ),
      }),
    ),
  }),
);

const HistoryMessages = Schema.optionalKey(
  Schema.Array(Schema.Struct({ message: Schema.Struct({ id: GmailId }) })),
);

const HistoryRecord = Schema.Struct({
  id: HistoryId,
  messagesAdded: HistoryMessages,
  messagesDeleted: HistoryMessages,
  labelsAdded: HistoryMessages,
  labelsRemoved: HistoryMessages,
});

const decodeHistory = json(
  Schema.Struct({
    history: Schema.optionalKey(Schema.Array(HistoryRecord)),
    nextPageToken: Schema.optionalKey(Schema.String),
    historyId: HistoryId,
  }),
);

const decodeLabels = json(
  Schema.Struct({
    labels: Schema.optionalKey(
      Schema.Array(
        Schema.Struct({
          id: Schema.String,
          name: Schema.String,
          type: Schema.optionalKey(Schema.String),
        }),
      ),
    ),
  }),
);

const decodeModified = json(
  Schema.Struct({
    id: GmailId,
    labelIds: Schema.optionalKey(Schema.Array(Schema.String)),
  }),
);

const decodeCreatedLabel = json(GmailLabelSchema);

const mailbox = /^\s*(?:"?(?<name>[^"<]*?)"?\s*)?<(?<address>[^<>]+)>\s*$/u;

const sender = (from: string) => {
  // Positional captures: Hermes leaves `groups` unset on some named-group results.
  const [, named, bracketed] = mailbox.exec(from) ?? [];
  const address = (bracketed ?? from).trim();
  const name = named?.trim() ?? '';
  return { sender: name === '' ? address : name, address };
};

// The document with `change` applied to the Inbox's messages and to every other view's.
export const everyView = (
  document: MailboxDocument,
  change: (
    view: string,
    messages: readonly GmailMessage[],
  ) => readonly GmailMessage[],
): MailboxDocument => ({
  ...document,
  messages: change('INBOX', document.messages),
  ...(document.views === undefined
    ? {}
    : {
        views: document.views.map((entry) => ({
          ...entry,
          messages: change(entry.label, entry.messages),
        })),
      }),
});

// The later of two Gmail history IDs already considered for notifications, as a document field:
// a view listing can rewind the checkpoint, never this boundary.
export const latestNotificationHistory = (
  ...ids: ReadonlyArray<string | undefined>
): Pick<MailboxDocument, 'notificationHistoryId'> => {
  const known = ids.filter((id) => id !== undefined);
  return known.length === 0
    ? {}
    : {
        notificationHistoryId: known.reduce((later, id) =>
          BigInt(id) > BigInt(later) ? id : later,
        ),
      };
};

// The messages a listing page leaves cached, and whether the listing continues.
const listedPage = (
  messages: readonly GmailMessage[],
  found: ReadonlyArray<readonly [string, GmailMessage | undefined]>,
  { seen, more }: Readonly<{ seen: readonly string[]; more: boolean }>,
) => {
  const merged = merge(messages, found);
  const listed = new Set(seen);
  const verified = merged.filter((message) => listed.has(message.id));
  if (more && verified.length < cacheLimit) {
    // Newly verified entries take priority over stale entries retained during a relisting.
    const retained = merged.filter((message) => !listed.has(message.id));
    return {
      done: false,
      messages: Arr.sort(
        [...verified, ...retained].slice(0, cacheLimit),
        newestFirst,
      ),
    };
  }
  // Messages kept from before this listing that it never saw have left the Inbox.
  return { done: true, messages: verified.slice(0, cacheLimit) };
};

// The deleted message IDs a history page names, and the others whose state may have changed.
const historyChanges = (records: ReadonlyArray<typeof HistoryRecord.Type>) => {
  const deleted = new Set(
    records.flatMap((record) =>
      (record.messagesDeleted ?? []).map(({ message }) => message.id),
    ),
  );
  const changed = Arr.dedupe(
    records.flatMap((record) =>
      [
        ...(record.messagesAdded ?? []),
        ...(record.labelsAdded ?? []),
        ...(record.labelsRemoved ?? []),
      ].map(({ message }) => message.id),
    ),
  ).filter((id) => !deleted.has(id));
  return { deleted, changed };
};

// Within a history page, the last record is a valid start for the next one.
const nextHistoryId = (
  page: Readonly<{ nextPageToken?: string; historyId: string }>,
  records: ReadonlyArray<Readonly<{ id: string }>>,
) =>
  page.nextPageToken === undefined
    ? page.historyId
    : (records.at(-1)?.id ?? page.historyId);

// The `boundary` parameter of a Content-Type header, quoted or not.
const boundaryParameter = (contentType: string | undefined) =>
  /;\s*boundary="?(?<boundary>[^";]+)"?/iu.exec(contentType ?? '')?.[1];

// Gmail's reads and writes for the Inbox store: listings, history, bodies, labels, search and
// sending. The store keeps what it reads.
export function createGmailReader(
  native: NativeGmailRequests,
  views: ReaderViews,
) {
  // One Gmail read; Gmail refusing a listing's page token is GmailInvalidPage.
  const gmail =
    (scope: MailboxScope) =>
    <A>(
      path: string,
      query: ReadonlyArray<readonly [string, string]>,
      decode: (body: unknown) => Effect.Effect<A, Schema.SchemaError>,
    ) =>
      providerRead(
        (signal) => native.gmailRequest(path, query, { ...scope, signal }),
        (status) =>
          status === 400 &&
          path === 'messages' &&
          query.some(([name]) => name === 'pageToken'),
        decode,
      );

  // Search results keep a message `anywhere` in Gmail; the Inbox keeps only its own.
  const metadata = (scope: MailboxScope, id: string, anywhere = false) =>
    gmail(scope)(
      `messages/${id}`,
      [
        ['format', 'metadata'],
        ['metadataHeaders', 'From'],
        ['metadataHeaders', 'Subject'],
      ],
      decodeMetadata,
    ).pipe(
      Effect.map((message) => {
        const labels = message.labelIds ?? [];
        const header = (name: string) =>
          message.payload?.headers?.find(
            (candidate) => candidate.name.toLowerCase() === name,
          )?.value;
        const received =
          anywhere || inInbox(labels)
            ? DateTime.make(Number(message.internalDate))
            : Option.none();
        return received.pipe(
          Option.map((date): GmailMessage => ({
            id: message.id,
            threadId: message.threadId,
            ...sender(header('from') ?? ''),
            subject: header('subject') ?? '',
            preview: unescapeHtml(message.snippet ?? ''),
            receivedAt: DateTime.formatIso(date),
            unread: labels.includes('UNREAD'),
            labels,
          })),
        );
      }),
      // A message that left the Inbox or Gmail is removed from the cache.
      Effect.catchTag('GmailNotFound', () => Effect.succeedNone),
      Effect.map((message) => [id, Option.getOrUndefined(message)] as const),
    );
  const fetchAll = (
    scope: MailboxScope,
    ids: readonly string[],
    anywhere = false,
  ) =>
    Effect.forEach(ids, (id) => metadata(scope, id, anywhere), {
      concurrency: 4,
    });

  // A new listing starts from the current history ID, or from the still-valid one it was given,
  // so changes during it are replayed after. Cached messages stay visible meanwhile; pending
  // changes, labels and other views carry over from the document it replaces. Without a valid
  // history ID, the other views are listed again.
  const startListing = Effect.fnUntraced(function* (
    scope: MailboxScope,
    previous: MailboxDocument | undefined,
    from?: string,
  ): Effect.fn.Return<
    MailboxDocument,
    SyncFailure | GmailNotFound | GmailInvalidPage
  > {
    const profile = yield* gmail(scope)('profile', [], decodeProfile);
    if (profile.emailAddress.toLowerCase() !== scope.address.toLowerCase()) {
      return yield* new SyncFailure({
        kind: 'authentication',
        cause: 'mailbox',
        diagnostic: 'another mailbox',
      });
    }
    return {
      ...previous,
      version: 1,
      messages: previous?.messages ?? [],
      checkpoint: {
        kind: 'backfill',
        historyId: from ?? profile.historyId,
        seen: [],
      },
      ...(from === undefined && previous?.views !== undefined
        ? {
            views: previous.views.map((entry) => ({
              ...entry,
              listing: { historyId: profile.historyId, seen: [] },
            })),
          }
        : {}),
    };
  });

  type Step = Effect.fn.Return<
    Option.Option<MailboxDocument>,
    SyncFailure | GmailNotFound | GmailInvalidPage
  >;
  type ListedView = ViewEntry &
    Readonly<{ listing: NonNullable<ViewEntry['listing']> }>;

  // The new Inbox mail each document a history page brought; its commit reports it.
  const arrivals = new WeakMap<MailboxDocument, readonly GmailMessage[]>();

  // Reads and reconciles one page for the Inbox or another Gmail view. Callers own their
  // checkpoint publication and recovery when Gmail rejects a page token.
  const readListingPage = Effect.fnUntraced(function* (
    scope: MailboxScope,
    { label: view, messages, listing }: ListedView,
  ) {
    const page = yield* gmail(scope)(
      'messages',
      [
        ...(view === allMail || view === gmailArchive
          ? []
          : [['labelIds', view] as const]),
        ...(view === gmailArchive
          ? [['q', '-in:inbox -in:sent -in:drafts'] as const]
          : []),
        // Gmail leaves Spam and Trash out of a listing unless it is asked to include them.
        ...(view === 'SPAM' || view === 'TRASH'
          ? [['includeSpamTrash', 'true'] as const]
          : []),
        ['maxResults', String(pageSize)],
        ...(listing.pageToken === undefined
          ? []
          : [['pageToken', listing.pageToken] as const]),
      ],
      decodeList,
    );
    const ids = (page.messages ?? []).map(({ id }) => id);
    const seen = Arr.dedupe([...listing.seen, ...ids]);
    const { nextPageToken } = page;
    const found = (yield* fetchAll(scope, ids, view !== 'INBOX')).map(
      ([id, message]) =>
        [
          id,
          message !== undefined && inView(view, labelsOf(message))
            ? message
            : undefined,
        ] as const,
    );
    return {
      ...listedPage(messages, found, {
        seen,
        more: nextPageToken !== undefined,
      }),
      seen,
      nextPageToken,
    };
  });

  // Lists the next Inbox page from a backfill checkpoint.
  const continueListing = Effect.fnUntraced(function* (
    scope: MailboxScope,
    document: MailboxDocument,
    checkpoint: Extract<MailboxDocument['checkpoint'], { kind: 'backfill' }>,
  ): Step {
    const page = yield* readListingPage(scope, {
      label: 'INBOX',
      messages: document.messages,
      listing: checkpoint,
    }).pipe(
      Effect.asSome,
      Effect.catchTag('GmailInvalidPage', () => Effect.succeedNone),
    );
    if (Option.isNone(page)) {
      return Option.some(
        yield* startListing(scope, document, checkpoint.historyId),
      );
    }
    const { nextPageToken, seen, messages, done } = page.value;
    return Option.some({
      ...document,
      messages,
      checkpoint:
        done || nextPageToken === undefined
          ? { kind: 'current', historyId: checkpoint.historyId }
          : { ...checkpoint, pageToken: nextPageToken, seen },
    });
  });
  // Applies one Gmail history page from a current checkpoint.
  // fallow-ignore-next-line complexity -- Each history record kind settles the cache, its views and the recorded changes.
  const applyHistory = Effect.fnUntraced(function* (
    scope: MailboxScope,
    document: MailboxDocument,
    checkpoint: Extract<MailboxDocument['checkpoint'], { kind: 'current' }>,
  ): Step {
    const forget = views.deletions();
    const history = yield* gmail(scope)(
      'history',
      [
        ['startHistoryId', checkpoint.historyId],
        ['historyTypes', 'messageAdded'],
        ['historyTypes', 'messageDeleted'],
        ['historyTypes', 'labelAdded'],
        ['historyTypes', 'labelRemoved'],
      ],
      decodeHistory,
    ).pipe(
      Effect.asSome,
      Effect.catchTag('GmailNotFound', () => Effect.succeedNone),
    );
    if (Option.isNone(history)) {
      // An expired or invalid history ID lists the Inbox again; cached messages stay visible.
      // Changes since then are unknown, so Historical Metadata Backfill lists All Mail again too.
      yield* logNote('Gmail history expired: listing the Inbox again');
      return Option.some(
        yield* startListing(
          scope,
          document.history === undefined
            ? document
            : { ...document, history: restarted(document.history) },
        ),
      );
    }
    const records = history.value.history ?? [];
    const historyId = nextHistoryId(history.value, records);
    if (records.length === 0 && historyId === checkpoint.historyId) {
      return Option.none();
    }
    const { deleted, changed } = historyChanges(records);
    const fetched = yield* fetchAll(
      scope,
      changed,
      document.views !== undefined || document.history !== undefined,
    );
    // Search results survive view removal, but not a confirmed deletion from Gmail.
    forget(deleted);
    const observed = document.notificationHistoryId ?? checkpoint.historyId;
    const added = new Set(
      records.flatMap((record) =>
        BigInt(record.id) > BigInt(observed)
          ? (record.messagesAdded ?? []).map(({ message }) => message.id)
          : [],
      ),
    );
    const arrived = fetched.flatMap(([id, message]) =>
      message !== undefined &&
      added.has(id) &&
      message.unread &&
      inInbox(labelsOf(message))
        ? [message]
        : [],
    );
    const announced = records.flatMap(
      (record) => record.messagesAdded ?? [],
    ).length;
    if (announced > 0) {
      yield* logNote(
        'Gmail history added messages:',
        announced,
        'after the notification boundary:',
        added.size,
        'unread in the Inbox:',
        arrived.length,
      );
    }
    // History cannot name the unchanged older message that now fits after an entry leaves, so
    // a full view that lost one is listed again.
    const refilled = new Set<string>();
    const next = everyView(document, (view, before) => {
      const after = merge(
        before,
        fetched.map(([id, message]) => [
          id,
          message !== undefined && inView(view, labelsOf(message))
            ? message
            : undefined,
        ]),
        deleted,
      );
      const remaining = new Set(after.map(({ id }) => id));
      if (
        before.length === cacheLimit &&
        before.some(({ id }) => !remaining.has(id))
      ) {
        refilled.add(view);
      }
      return after.slice(0, cacheLimit);
    });
    const updated: MailboxDocument = {
      ...next,
      ...(next.history === undefined
        ? {}
        : {
            history: recorded(next.history, [
              ...fetched,
              ...Array.from(deleted, (id) => [id, undefined] as const),
            ]),
          }),
      ...latestNotificationHistory(observed, historyId),
      ...(next.views === undefined
        ? {}
        : {
            views: next.views.map((entry) =>
              entry.listing === undefined && refilled.has(entry.label)
                ? { ...entry, listing: { historyId, seen: [] } }
                : entry,
            ),
          }),
    };
    const advanced: MailboxDocument = refilled.has('INBOX')
      ? yield* startListing(scope, updated, historyId)
      : { ...updated, checkpoint: { kind: 'current', historyId } };
    arrivals.set(advanced, arrived);
    return Option.some(advanced);
  });

  // Lists the next page of a view, as continueListing does for the Inbox.
  const continueView = Effect.fnUntraced(function* (
    scope: MailboxScope,
    document: MailboxDocument,
    entry: ListedView,
  ): Step {
    const { listing } = entry;
    const { messages, done, seen, nextPageToken } = yield* readListingPage(
      scope,
      entry,
    );
    const next: ViewEntry = {
      label: entry.label,
      messages,
      ...(done || nextPageToken === undefined
        ? {}
        : {
            listing: {
              historyId: listing.historyId,
              pageToken: nextPageToken,
              seen,
            },
          }),
    };
    return Option.some({
      ...document,
      // History may have advanced while this listing was interrupted. Preserve any earlier
      // replay another completed listing needs so unseen additions discarded by listedPage return.
      ...(next.listing === undefined
        ? {
            checkpoint: {
              kind: 'current' as const,
              historyId:
                document.checkpoint.kind === 'current' &&
                BigInt(document.checkpoint.historyId) <
                  BigInt(listing.historyId)
                  ? document.checkpoint.historyId
                  : listing.historyId,
            },
          }
        : {}),
      views: (document.views ?? []).map((view) =>
        view.label === entry.label ? next : view,
      ),
    });
  });

  // The next page of a view, or none when Gmail cannot list it now: the view keeps its saved
  // messages until the next synchronization, which lists it from its first page when Gmail
  // refused its page token.
  const listView = (
    scope: MailboxScope,
    document: MailboxDocument,
    listing: ListedView,
  ) => {
    const failed = Effect.sync(() => {
      views.failed.add(listing.label);
    });
    return continueView(scope, document, listing).pipe(
      Effect.catchTags({
        GmailNotFound: () => failed.pipe(Effect.as(Option.none())),
        GmailInvalidPage: () =>
          failed.pipe(
            Effect.as(
              Option.some({
                ...document,
                views: (document.views ?? []).map((view) =>
                  view === listing
                    ? {
                        ...view,
                        listing: {
                          historyId: listing.listing.historyId,
                          seen: [],
                        },
                      }
                    : view,
                ),
              }),
            ),
          ),
        SyncFailure: (failure) =>
          failure.kind === 'retry'
            ? failed.pipe(Effect.as(Option.none()))
            : Effect.fail(failure),
      }),
    );
  };

  // The next document to commit, or none when the cache is current. After the Inbox's own
  // listing, a requested view becomes the most recently opened and the views are listed, before
  // the history that keeps them all current.
  const advance = (
    scope: MailboxScope,
    document: MailboxDocument | undefined,
  ): Effect.Effect<
    Option.Option<MailboxDocument>,
    SyncFailure | GmailNotFound | GmailInvalidPage
  > => {
    if (document === undefined) {
      return startListing(scope, undefined).pipe(Effect.asSome);
    }
    const { checkpoint } = document;
    if (checkpoint.kind === 'backfill') {
      return continueListing(scope, document, checkpoint);
    }
    // A cache written before messages kept their labels needs a fresh Inbox listing.
    if (
      checkpoint.kind !== 'current' ||
      document.messages.some(({ labels }) => labels === undefined)
    ) {
      return startListing(scope, document).pipe(Effect.asSome);
    }
    // Seed older caches before a view listing can rewind their history checkpoint.
    if (document.notificationHistoryId === undefined) {
      return Effect.succeedSome({
        ...document,
        notificationHistoryId: checkpoint.historyId,
      });
    }
    const opened = views.opened(document, checkpoint.historyId);
    if (opened !== undefined) {
      return Effect.succeedSome(opened);
    }
    const listing = document.views?.find(
      (view): view is ListedView =>
        view.listing !== undefined && !views.failed.has(view.label),
    );
    if (listing !== undefined) {
      return listView(scope, document, listing).pipe(
        Effect.filterOrElse(Option.isSome, () => advance(scope, document)),
      );
    }
    return applyHistory(scope, document, checkpoint);
  };

  // One Gmail body read; listing-page token errors cannot occur for these resources.
  const gmailRead =
    (scope: MailboxScope) =>
    <A>(
      path: string,
      query: ReadonlyArray<readonly [string, string]>,
      decode: (body: unknown) => Effect.Effect<A, Schema.SchemaError>,
    ) =>
      gmail(scope)(path, query, decode).pipe(
        Effect.catchTag('GmailInvalidPage', Effect.die),
      );

  // A part's bytes and their exact size: inline in the message, or served separately when Gmail
  // splits a large part. Only complete data matching Gmail's declared size is returned.
  const gmailPartData = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    part: GmailPart,
  ) {
    const { attachmentId } = part.body ?? {};
    const downloaded =
      attachmentId === undefined
        ? { data: part.body?.data ?? '', size: part.body?.size }
        : yield* gmailRead(scope)(
            `messages/${id}/attachments/${attachmentId}`,
            [],
            decodeAttachment,
          );
    if (downloaded.size !== part.body?.size) {
      return yield* new SyncFailure({
        kind: 'retry',
        cause: 'body size',
        diagnostic: 'incomplete body',
      });
    }
    return { data: downloaded.data, size: downloaded.size };
  });

  const fullMessage = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    query: ReadonlyArray<readonly [string, string]>,
  ): Effect.fn.Return<ProviderPayload, SyncFailure | GmailNotFound> {
    const message = yield* gmailRead(scope)(
      `messages/${id}`,
      query,
      decodeFullMessage,
    );
    if (message.id !== id) {
      return yield* new SyncFailure({
        kind: 'retry',
        cause: 'message',
        diagnostic: 'another message',
      });
    }
    return message.payload;
  });

  // Lists the next All Mail page into a new segment. Messages it lists again replace the changes
  // recorded for them; an expired page token starts a new pass.
  const listHistory = Effect.fnUntraced(function* (
    scope: MailboxScope,
    history: MailboxHistory,
  ) {
    const { pageToken } = history.current;
    const page = yield* gmail(scope)(
      'messages',
      [
        ['maxResults', String(historyPageSize)],
        ...(pageToken === undefined ? [] : [['pageToken', pageToken] as const]),
      ],
      decodeList,
    ).pipe(
      Effect.asSome,
      Effect.catchTag('GmailInvalidPage', () => Effect.succeedNone),
    );
    if (Option.isNone(page)) {
      return { history: restarted(history), written: [] };
    }
    const pageMessages = yield* fetchAll(
      scope,
      (page.value.messages ?? []).map(({ id }) => id),
      true,
    );
    const messages = Arr.sort(
      pageMessages.flatMap(([, message]) =>
        message !== undefined && inView(allMail, labelsOf(message))
          ? [message]
          : [],
      ),
      newestFirst,
    );
    const changed = new Set(history.changes.map(({ id }) => id));
    const name = yield* segmentName;
    return {
      history: listedHistory(
        recorded(
          history,
          pageMessages.filter(([id]) => changed.has(id)),
        ),
        { name, count: messages.length },
        {
          pageToken: page.value.nextPageToken,
          ids: messages.map(({ id }) => id),
        },
      ),
      written: messages.length === 0 ? [] : [[name, messages] as const],
    };
  });

  const readLabels = (scope: MailboxScope, message: GmailMessage) =>
    gmail(scope)(
      `messages/${message.id}`,
      [['format', 'metadata']],
      decodeModified,
    ).pipe(
      Effect.flatMap((value) =>
        value.id === message.id
          ? Effect.succeed(value.labelIds ?? [])
          : Effect.fail(
              new SyncFailure({
                kind: 'retry',
                cause: 'message mismatch',
                diagnostic: 'another message',
              }),
            ),
      ),
      Effect.asSome,
      Effect.catchTag('GmailNotFound', () => Effect.succeedNone),
    );

  // Gmail's labels after one modify, or none when Gmail refuses the change for good: the message
  // or label no longer exists. A label change applied twice leaves the same labels, so a request
  // whose response was lost is safely sent again.
  const modify = Effect.fnUntraced(function* (
    scope: MailboxScope,
    { action, message }: PendingAction,
  ) {
    const modified = yield* providerWrite(
      () =>
        native.gmailModify(
          { message: message.id, add: action.add, remove: action.remove },
          scope,
        ),
      (status) => status === 200,
      decodeModified,
    );
    if (Option.isSome(modified) && modified.value.id !== message.id) {
      return yield* new SyncFailure({
        kind: 'retry',
        cause: 'message mismatch',
        diagnostic: 'another message',
      });
    }
    return modified.pipe(Option.map(({ labelIds }) => labelIds ?? []));
  });

  // Gmail's user labels, by name; Gmail lists every one.
  const gmailLabels = (scope: MailboxScope) =>
    gmail(scope)('labels', [], decodeLabels).pipe(
      Effect.map((response) => ({
        labels: Arr.sort(
          (response.labels ?? [])
            .filter(({ type }) => type === 'user')
            .map(({ id, name }) => ({ id, name }))
            // A label whose ID this client cannot send is left out rather than failing the list.
            .filter(Schema.is(GmailLabelSchema)),
          Order.mapInput(Order.String, (label: GmailLabel) => label.name),
        ),
        limited: false,
      })),
    );

  // One page of Gmail's own search of this mailbox, newest first as Gmail orders it.
  const gmailSearch = Effect.fnUntraced(function* (
    scope: MailboxScope,
    { query, pageToken }: Readonly<{ query: string; pageToken?: string }>,
    limit: number,
  ) {
    const page = yield* gmail(scope)(
      'messages',
      [
        ['q', query],
        ['maxResults', String(limit)],
        ...(pageToken === undefined ? [] : [['pageToken', pageToken] as const]),
      ],
      decodeList,
    );
    const messages = (yield* Effect.forEach(
      (page.messages ?? []).map(({ id }) => id),
      (id) => metadata(scope, id, true),
      { concurrency: 4 },
    )).flatMap(([, message]) => (message === undefined ? [] : [message]));
    return { messages, next: page.nextPageToken };
  });

  // Gmail's evidence for a message whose handoff had no answer: sent only when exactly one of the
  // newest Sent messages carries its MIME boundary. Anything else leaves the outcome unknown.
  const sentWith = Effect.fnUntraced(function* (
    scope: MailboxScope,
    boundary: string,
  ) {
    const page = yield* gmail(scope)(
      'messages',
      [
        ['labelIds', 'SENT'],
        ['maxResults', String(sentPageSize)],
      ],
      decodeList,
    );
    const matches = yield* Effect.forEach(
      page.messages ?? [],
      ({ id }) =>
        gmail(scope)(
          `messages/${id}`,
          [
            ['format', 'metadata'],
            ['metadataHeaders', 'Content-Type'],
          ],
          decodeMetadata,
        ).pipe(
          Effect.map((message) =>
            boundaryParameter(
              message.payload?.headers?.find(
                ({ name }) => name.toLowerCase() === 'content-type',
              )?.value,
            ) === boundary
              ? [message.id]
              : [],
          ),
          // A message deleted meanwhile is not this one.
          Effect.catchTag('GmailNotFound', () => Effect.succeed([])),
        ),
      { concurrency: 4 },
    );
    const [match, ...others] = matches.flat();
    return match !== undefined && others.length === 0
      ? ({ kind: 'sent', message: match } as const)
      : ({ kind: 'unknown' } as const);
  });

  // The next step of Historical Metadata Backfill: a due fold of recorded changes, or the next
  // All Mail page. Gmail counts the mailbox's messages before the first.
  const nextHistory = Effect.fnUntraced(function* <E>(
    scope: MailboxScope,
    document: MailboxDocument,
    options: Readonly<{
      read: (name: string) => Effect.Effect<readonly GmailMessage[], E>;
      newName: Effect.Effect<string>;
    }>,
  ) {
    if (document.checkpoint.kind !== 'current') {
      return Option.none();
    }
    let { history } = document;
    if (history === undefined) {
      const { messagesTotal } = yield* gmail(scope)(
        'profile',
        [],
        decodeProfile,
      );
      history = {
        ...(messagesTotal === undefined ? {} : { total: messagesTotal }),
        current: { segments: [] },
        changes: [],
      };
    }
    const folding = foldDue(history);
    if (!folding && history.current.complete === true) {
      return Option.none();
    }
    const step = folding
      ? yield* foldStep(history, options.read, options.newName)
      : yield* listHistory(scope, history);
    return Option.some({
      document: { ...document, history: step.history },
      written: step.written,
      keep: segmentNames(step.history),
    });
  });

  return {
    advance,
    // A Gmail view is unfinished while listed.
    unfinished: (entry: ViewEntry) => entry.listing !== undefined,
    arrivals: (document: MailboxDocument) => arrivals.get(document) ?? [],
    history: nextHistory,
    sameProgress: () => true,
    partData: gmailPartData,
    fullMessage,
    prefetched: (scope: MailboxScope, id: string) =>
      fullMessage(scope, id, [['format', 'full']]),
    invitations: true,
    labels: gmailLabels,
    readLabels,
    modify,
    offers: () => true,
    applied: () => true,
    unavailableActions: () => undefined,
    search: gmailSearch,
    sentCopy: (
      scope: MailboxScope,
      { boundary }: Readonly<{ boundary: string }>,
    ) => sentWith(scope, boundary),
    send: (message: OutgoingSend, scope: MailboxScope) =>
      native.gmailSend(message, scope),
    sendRefusalRejectsGrant: false,
    createLabel: (scope: MailboxScope, name: string) =>
      providerWrite(
        () => native.gmailCreateLabel(name, scope),
        (status) => status === 200,
        decodeCreatedLabel,
      ),
    message: (scope: MailboxScope, id: string) =>
      metadata(scope, id, true).pipe(Effect.map(([, message]) => message)),
  } satisfies ProviderReader;
}
