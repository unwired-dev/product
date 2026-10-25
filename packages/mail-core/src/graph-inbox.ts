import type * as Schema from 'effect/Schema';

import * as Arr from 'effect/Array';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';

import type { GmailLabel } from './gmail-actions.ts';
import type {
  GmailMessage,
  MailboxDocument,
  MailboxScope,
  PendingAction,
} from './mailbox-document.ts';
import type { GmailInvalidPage, NativeGraphMailbox } from './mailbox-read.ts';
import type { GmailPart } from './message-body.ts';
import type { FolderRoles, GraphAttachmentInfo } from './microsoft-graph.ts';

import {
  cacheLimit,
  merge,
  newestFirst,
  sameMailbox,
} from './mailbox-document.ts';
import {
  GmailNotFound,
  providerRead,
  providerWrite,
  rejectedGrant,
  SyncFailure,
} from './mailbox-read.ts';
import {
  decodeGraphAttachments,
  decodeGraphCopies,
  decodeGraphDelta,
  decodeGraphFile,
  decodeGraphFolder,
  decodeGraphFolders,
  decodeGraphFull,
  decodeGraphInbox,
  decodeGraphListed,
  decodeGraphPlacement,
  decodeGraphSearch,
  deltaIds,
  fileAttachments,
  fileData,
  graphAttachment,
  graphAttachments,
  graphChange,
  graphChildFolders,
  graphFolders,
  graphDelta,
  graphFolderMessage,
  graphMessages,
  graphLabels,
  graphMessage,
  graphPayload,
  graphPlacement,
  graphSearch,
  graphSentCopies,
  graphUnavailableActions,
  graphWellKnownFolder,
  isGraphSearchLink,
  listedMessage,
  wellKnownFolders,
} from './microsoft-graph.ts';

export type ProviderPayload = GmailPart &
  Readonly<{
    attachmentsPending?: boolean;
    authentication?: boolean;
  }>;

// Every delta page links to the next page or, at the round's end, to the changes after it.
const pageLink = ({
  '@odata.nextLink': next,
  '@odata.deltaLink': end,
}: Readonly<{ '@odata.nextLink'?: string; '@odata.deltaLink'?: string }>) => {
  const link = next ?? end;
  return link === undefined
    ? Effect.fail(
        new SyncFailure({
          kind: 'retry',
          cause: 'delta',
          diagnostic: 'delta page without link',
        }),
      )
    : Effect.succeed(link);
};

type DeltaItems = Parameters<typeof deltaIds>[0];
type PendingChange = Pick<PendingAction, 'action' | 'message'>;

// The most folders Move to lists for one mailbox.
const folderLimit = 250;

// The new Inbox mail one delta page brought: unread and not already cached, so an update to a
// listed message is not. A full cache has dropped its oldest messages, so an uncached one no newer
// than the oldest kept may have been listed or reported before, as when Graph changes a dropped
// message or names an arrival again after newer mail.
const deltaArrivals = (
  document: MailboxDocument,
  changed: ReadonlyArray<readonly [string, GmailMessage | undefined]>,
) => {
  const known = new Set(document.messages.map(({ id }) => id));
  const evictedUntil = cacheEdge(document) ?? '';
  return changed.flatMap(([id, message]) =>
    message?.unread === true &&
    !known.has(id) &&
    message.receivedAt > evictedUntil
      ? [message]
      : [],
  );
};

// Keep the previous eviction edge until refill, advancing it if settlements fill the cache and
// evict newer mail. No edge is needed while the cache holds the whole Inbox.
function cacheEdge({ checkpoint, messages }: MailboxDocument) {
  const refillUntil =
    checkpoint.kind === 'graph-current' ? checkpoint.refillUntil : undefined;
  return messages.length === cacheLimit
    ? Order.max(Order.String)(
        refillUntil ?? '',
        messages.at(-1)?.receivedAt ?? '',
      )
    : refillUntil;
}

type GraphCheckpoint = Extract<
  MailboxDocument['checkpoint'],
  { kind: 'graph-listing' | 'graph-current' }
>;
const isGraphCheckpoint = (
  checkpoint: MailboxDocument['checkpoint'],
): checkpoint is GraphCheckpoint =>
  checkpoint.kind === 'graph-listing' || checkpoint.kind === 'graph-current';

// Graph's synchronization and body reads share the store's cache and presentation boundaries.
export function createGraphReader(native: NativeGraphMailbox) {
  // Checkpoints that saved the link of an empty delta round; their folder is current. Documents and
  // views derived from one keep it.
  const quiet = new WeakSet<GraphCheckpoint>();
  // The new Inbox mail each document's delta page brought, which its commit reports.
  const arrivals = new WeakMap<MailboxDocument, readonly GmailMessage[]>();
  // One Graph read; a delta link Graph no longer accepts is GmailInvalidPage.
  const graphRead =
    (scope: MailboxScope) =>
    <A>(
      url: string,
      decode: (body: unknown) => Effect.Effect<A, Schema.SchemaError>,
    ) =>
      providerRead(
        (signal) => native.graphRequest(url, { ...scope, signal }),
        (status) =>
          status === 410 || (status === 400 && url.includes('/delta?')),
        decode,
      );

  // A Graph read of a resource that is not a delta round.
  const graphGet =
    (scope: MailboxScope) =>
    <A>(
      url: string,
      decode: (body: unknown) => Effect.Effect<A, Schema.SchemaError>,
    ) =>
      graphRead(scope)(url, decode).pipe(
        Effect.catchTag('GmailInvalidPage', Effect.die),
      );

  // A folder's newest messages replace the cached ones; the delta round keeps them current.
  // Pending changes and labels carry over from the document it replaces.
  const listGraph = Effect.fnUntraced(function* (
    scope: MailboxScope,
    previous: MailboxDocument | undefined,
    {
      checkpoint,
      until,
      view,
    }: Readonly<{
      checkpoint: MailboxDocument['checkpoint'];
      until?: string;
      view: string;
    }>,
  ) {
    let url = graphMessages(view, cacheLimit, until);
    const messages = new Map<string, GmailMessage>();
    // A page may be shorter than $top. Bound even empty or repeated continuation pages.
    for (let pages = 0; pages < cacheLimit; pages += 1) {
      const page = yield* graphGet(scope)(url, decodeGraphInbox);
      for (const message of page.value) {
        messages.set(
          message.id,
          listedMessage(message, [
            view,
            ...(message.isRead === false ? ['UNREAD'] : []),
          ]),
        );
      }
      const next = page['@odata.nextLink'];
      if (next === undefined || messages.size >= cacheLimit) {
        return {
          ...previous,
          version: 1,
          messages: Arr.sort([...messages.values()], newestFirst).slice(
            0,
            cacheLimit,
          ),
          checkpoint,
        } satisfies MailboxDocument;
      }
      url = next;
    }
    return yield* new SyncFailure({
      kind: 'retry',
      cause: 'listing',
      diagnostic: 'listing page limit',
    });
  });

  // Applies one page of later changes. Graph cannot name the unchanged older message that now
  // fits after a full cache loses one, so the Inbox is listed again then for messages no newer than
  // the oldest previously kept; newer listed mail is left to the delta page that classifies it.
  const applyDelta = Effect.fnUntraced(function* (
    scope: MailboxScope,
    document: MailboxDocument,
    {
      items,
      link,
      view,
    }: Readonly<{ items: DeltaItems; link: string; view: string }>,
  ) {
    const changed = yield* Effect.forEach(
      deltaIds(items),
      (id) =>
        graphGet(scope)(graphFolderMessage(view, id), decodeGraphListed).pipe(
          Effect.map(
            (message) =>
              [
                id,
                listedMessage(message, [
                  view,
                  ...(message.isRead === false ? ['UNREAD'] : []),
                ]),
              ] as const,
          ),
          Effect.catchTag('GmailNotFound', () =>
            Effect.succeed([id, undefined] as const),
          ),
        ),
      { concurrency: 4 },
    );
    const merged = merge(document.messages, changed);
    const current = { kind: 'graph-current', link } as const;
    let messages = merged.slice(0, cacheLimit);
    const edge = cacheEdge(document);
    if (edge !== undefined && merged.length < cacheLimit) {
      const kept = new Set(merged.map(({ id }) => id));
      // Filter at the provider so pending newer arrivals cannot crowd older refill rows out.
      const listed = yield* listGraph(scope, document, {
        checkpoint: current,
        until: edge,
        view,
      });
      messages = Arr.sort(
        [
          ...merged,
          ...listed.messages.filter(
            ({ id, receivedAt }) => !kept.has(id) && receivedAt <= edge,
          ),
        ],
        newestFirst,
      ).slice(0, cacheLimit);
    }
    const next = {
      ...document,
      messages,
      checkpoint: current,
    } satisfies MailboxDocument;
    if (view === 'INBOX') {
      arrivals.set(next, deltaArrivals(document, changed));
    }
    return next;
  });

  // An unchanged Inbox still saves the round's link, as Graph asks, so a quiet mailbox never waits
  // on an expiring one; saving it ends this synchronization.
  const quietRound = (document: MailboxDocument, link: string) => {
    if ('link' in document.checkpoint && document.checkpoint.link === link) {
      return Option.none();
    }
    const checkpoint: GraphCheckpoint =
      document.checkpoint.kind === 'graph-current'
        ? { ...document.checkpoint, link }
        : { kind: 'graph-current', link };
    quiet.add(checkpoint);
    return Option.some({ ...document, checkpoint });
  };

  // A Microsoft Inbox lists its newest messages, runs one delta round to the link for later
  // changes and lists again, so nothing changed during the round is missed. Each later round
  // applies its pages; an expired link starts over with the cached messages still shown.
  const advanceRound = Effect.fnUntraced(function* (
    scope: MailboxScope,
    document: MailboxDocument | undefined,
    view: string,
  ): Effect.fn.Return<
    Option.Option<MailboxDocument>,
    SyncFailure | GmailNotFound | GmailInvalidPage
  > {
    const listing = { kind: 'graph-listing' } as const;
    if (document === undefined || !isGraphCheckpoint(document.checkpoint)) {
      return Option.some(
        yield* listGraph(scope, document, { checkpoint: listing, view }),
      );
    }
    const { checkpoint } = document;
    const page = yield* graphRead(scope)(
      checkpoint.link ?? graphDelta(view),
      decodeGraphDelta,
    ).pipe(
      Effect.asSome,
      Effect.catchTag('GmailInvalidPage', () => Effect.succeedNone),
    );
    if (Option.isNone(page)) {
      return Option.some(
        yield* listGraph(scope, document, { checkpoint: listing, view }),
      );
    }
    const next = page.value['@odata.nextLink'];
    const link = yield* pageLink(page.value);
    if (checkpoint.kind === 'graph-listing') {
      return Option.some(
        next === undefined
          ? yield* listGraph(scope, document, {
              checkpoint: { kind: 'graph-current', link },
              view,
            })
          : { ...document, checkpoint: { kind: 'graph-listing', link } },
      );
    }
    return page.value.value.length > 0 || next !== undefined
      ? Option.some(
          yield* applyDelta(scope, document, {
            items: page.value.value,
            link,
            view,
          }),
        )
      : quietRound(document, link);
  });

  // A Graph attachment's bytes. Graph declares approximate attachment sizes, so the decoded bytes
  // report their own.
  const partData = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    attachmentId: string,
  ) {
    const file = yield* graphGet(scope)(
      graphAttachment(id, attachmentId),
      decodeGraphFile,
    );
    const bytes = fileData(file.contentBytes);
    if (bytes === undefined) {
      return yield* new SyncFailure({
        kind: 'retry',
        cause: 'body size',
        diagnostic: 'invalid attachment encoding',
      });
    }
    return bytes;
  });

  const graphAttachmentMetadata = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
  ) {
    const attachments: GraphAttachmentInfo[] = [];
    let url: string | undefined = graphAttachments(id);
    // Bound even empty pages, and keep the tree within the existing MIME-part budget.
    for (let pages = 0; url !== undefined; pages += 1) {
      if (pages >= 200) {
        return {
          attachments: [],
          attachmentsPending: true,
          authentication: false,
        };
      }
      const reply: Readonly<{
        page:
          | Effect.Success<ReturnType<typeof decodeGraphAttachments>>
          | undefined;
        authentication: boolean;
      }> = yield* graphGet(scope)(url, decodeGraphAttachments).pipe(
        Effect.map((page) => ({ page, authentication: false })),
        Effect.catchIf(
          (failure) =>
            failure instanceof GmailNotFound ||
            failure.kind === 'retry' ||
            failure.kind === 'authentication',
          (failure) =>
            Effect.succeed({
              page: undefined,
              authentication: rejectedGrant(failure),
            }),
        ),
      );
      const { page, authentication } = reply;
      if (page === undefined || attachments.length + page.value.length > 500) {
        return { attachments: [], attachmentsPending: true, authentication };
      }
      attachments.push(...fileAttachments(page.value));
      url = page['@odata.nextLink'];
    }
    return { attachments, attachmentsPending: false, authentication: false };
  });

  // Attachment metadata supplies Content-IDs; only the shared visible-image admission reads bytes.
  const fullMessage = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
  ) {
    const message = yield* graphGet(scope)(graphMessage(id), decodeGraphFull);
    if (message.id !== id) {
      return yield* new SyncFailure({
        kind: 'retry',
        cause: 'message',
        diagnostic: 'another message',
      });
    }
    // Graph reports no attachments for a message whose only ones are inline.
    const { attachments, attachmentsPending, authentication } =
      message.hasAttachments === true ||
      (message.body.contentType === 'html' &&
        /cid:/iu.test(message.body.content))
        ? yield* graphAttachmentMetadata(scope, id)
        : { attachments: [], attachmentsPending: false, authentication: false };
    return {
      ...graphPayload(message, attachments),
      attachmentsPending,
      authentication,
    };
  });

  // A document that saved a quiet round's link is current until the next synchronization.
  const advance = (
    scope: MailboxScope,
    document: MailboxDocument | undefined,
    step: number,
  ) => {
    if (
      document !== undefined &&
      isGraphCheckpoint(document.checkpoint) &&
      quiet.has(document.checkpoint)
    ) {
      return Effect.succeedNone;
    }
    // Caches saved before organizing keep no labels; listing again adds them, and the round
    // continues from its saved link.
    if (
      document !== undefined &&
      isGraphCheckpoint(document.checkpoint) &&
      document.messages.some(({ labels }) => labels === undefined)
    ) {
      return listGraph(scope, document, {
        checkpoint: document.checkpoint,
        view: 'INBOX',
      }).pipe(Effect.asSome);
    }
    if (step >= 200) {
      return Effect.fail(
        new SyncFailure({
          kind: 'retry',
          cause: 'delta',
          diagnostic: 'delta page limit',
        }),
      );
    }
    return advanceRound(scope, document, 'INBOX');
  };

  // The next step of a folder view's own round, as for the Inbox, or none once a quiet round saved
  // its link. A folder never listed is listed first.
  const advanceView = Effect.fnUntraced(function* (
    scope: MailboxScope,
    entry: Readonly<{
      label: string;
      messages: readonly GmailMessage[];
      checkpoint?: GraphCheckpoint;
    }>,
  ) {
    if (entry.checkpoint !== undefined && quiet.has(entry.checkpoint)) {
      return Option.none();
    }
    const next = yield* advanceRound(
      scope,
      entry.checkpoint === undefined
        ? undefined
        : {
            version: 1,
            messages: entry.messages,
            checkpoint: entry.checkpoint,
          },
      entry.label,
    );
    return next.pipe(
      Option.flatMap(({ messages, checkpoint }) =>
        isGraphCheckpoint(checkpoint)
          ? Option.some({ label: entry.label, messages, checkpoint })
          : Option.none(),
      ),
    );
  });

  // The mailbox's well-known folders by ID, read once per open mailbox; a mailbox without one, such
  // as Archive, simply lacks it.
  let known: Readonly<{ scope: MailboxScope; roles: FolderRoles }> | undefined =
    undefined;
  const folderRoles = Effect.fnUntraced(function* (scope: MailboxScope) {
    if (known !== undefined && sameMailbox(known.scope, scope)) {
      return known.roles;
    }
    const found = yield* Effect.forEach(
      wellKnownFolders,
      (name) =>
        graphGet(scope)(graphWellKnownFolder(name), decodeGraphFolder).pipe(
          Effect.map(({ id }) => [[id, name] as const]),
          Effect.catchTag('GmailNotFound', () => Effect.succeed([])),
        ),
      { concurrency: 4 },
    );
    const roles: FolderRoles = new Map(found.flat());
    known = { scope, roles };
    return roles;
  });
  const placed = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    message: Effect.Success<ReturnType<typeof decodeGraphPlacement>>,
  ) {
    if (message.id !== id) {
      return yield* new SyncFailure({
        kind: 'retry',
        cause: 'message mismatch',
        diagnostic: 'another message',
      });
    }
    const roles = yield* folderRoles(scope);
    return graphLabels(message.parentFolderId, message.isRead, roles);
  });

  // Move to's folders: every folder apart from the well-known ones, nested ones included, each
  // named by its path so equal names stay apart. Listing stops at `folderLimit` folders or a
  // folder's first page; `limited` says whether any were left out.
  const labels = Effect.fnUntraced(function* (scope: MailboxScope) {
    const roles = yield* folderRoles(scope);
    const listed: GmailLabel[] = [];
    let limited = false;
    // Breadth first, so a limit leaves out the deepest folders. Keep the provider's names
    // and identify Inbox ancestry by role, so hosts can localize only that parent.
    const queue: Array<{
      url: string;
      path: readonly string[];
      inbox: boolean;
    }> = [{ url: graphFolders, path: [], inbox: false }];
    for (let next = queue.shift(); next !== undefined; next = queue.shift()) {
      if (listed.length >= folderLimit) {
        limited = true;
        break;
      }
      const page = yield* graphGet(scope)(next.url, decodeGraphFolders);
      limited ||= page['@odata.nextLink'] !== undefined;
      for (const { id, displayName, childFolderCount = 0 } of page.value) {
        const path = [...next.path, displayName];
        if (!roles.has(id)) {
          listed.push({
            id,
            name: path.join(' / '),
            path,
            inboxPath: next.inbox,
          });
        }
        if (childFolderCount > 0) {
          queue.push({
            url: graphChildFolders(id),
            path,
            inbox: next.inbox || roles.get(id) === 'inbox',
          });
        }
      }
    }
    return {
      labels: Arr.sort(
        listed.slice(0, folderLimit),
        Order.mapInput(Order.String, (label: GmailLabel) => label.name),
      ),
      limited: limited || listed.length > folderLimit,
    };
  });

  // A message's labels as Graph has it now, or none once Graph no longer has it.
  const readLabels = Effect.fnUntraced(function* (
    scope: MailboxScope,
    message: Readonly<{ id: string }>,
  ) {
    const found = yield* graphGet(scope)(
      graphPlacement(message.id),
      decodeGraphPlacement,
    ).pipe(Effect.catchTag('GmailNotFound', () => Effect.void));
    return found === undefined
      ? Option.none<readonly string[]>()
      : Option.some(yield* placed(scope, message.id, found));
  });

  // Graph's labels after one change, or none when Graph refuses it for good: the message or folder
  // no longer exists, or the action has no Graph change. A change sets a state rather than
  // toggling one, so a request whose reply was lost is safely sent again.
  const modify = Effect.fnUntraced(function* (
    scope: MailboxScope,
    { action, message }: PendingChange,
  ) {
    const change = graphChange(action);
    const changed =
      change === undefined
        ? Option.none()
        : yield* providerWrite(
            () => native.graphModify({ message: message.id, ...change }, scope),
            (status) => status === 200 || status === 201,
            decodeGraphPlacement,
          );
    return Option.isNone(changed)
      ? Option.none<readonly string[]>()
      : Option.some(yield* placed(scope, message.id, changed.value));
  });

  // One page of Graph's search of every folder. Each result is labeled with where it is now.
  const search = Effect.fnUntraced(function* (
    scope: MailboxScope,
    { query, pageToken }: Readonly<{ query: string; pageToken?: string }>,
    limit: number,
  ) {
    // A page token this Inbox never issued is refused before it reaches native code.
    if (pageToken !== undefined && !isGraphSearchLink(pageToken)) {
      return yield* new GmailNotFound();
    }
    const page = yield* graphGet(scope)(
      pageToken ?? graphSearch(query, limit),
      decodeGraphSearch,
    );
    const roles = yield* folderRoles(scope);
    return {
      messages: page.value.map((message) =>
        listedMessage(
          message,
          graphLabels(message.parentFolderId, message.isRead, roles),
        ),
      ),
      next: page['@odata.nextLink'],
    };
  });

  // Sent Items' evidence for a message whose handoff had no answer: sent only when exactly one copy
  // carries its Message-ID. Microsoft files the copy after accepting the message, so a copy that
  // is not there yet leaves the outcome unknown.
  const sentCopy = Effect.fnUntraced(function* (
    scope: MailboxScope,
    messageId: string,
  ) {
    const copies = yield* graphGet(scope)(
      graphSentCopies(messageId),
      decodeGraphCopies,
    );
    const [copy, ...others] = copies.value;
    return copy !== undefined &&
      others.length === 0 &&
      copies['@odata.nextLink'] === undefined
      ? { kind: 'sent' as const, message: copy.id }
      : { kind: 'unknown' as const };
  });

  return {
    advance,
    advanceView,
    // The new Inbox mail the delta page that produced `document` brought; listings bring none.
    arrivals: (document: MailboxDocument) => arrivals.get(document) ?? [],
    partData,
    fullMessage,
    labels,
    readLabels,
    modify,
    search,
    sentCopy,
    unavailableActions: () => graphUnavailableActions(known?.roles),
  } as const;
}
