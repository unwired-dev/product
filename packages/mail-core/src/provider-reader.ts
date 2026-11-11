import type * as Effect from 'effect/Effect';
import type * as Option from 'effect/Option';

import type { GmailAction, GmailLabel } from './gmail-actions.ts';
import type {
  GmailMessage,
  MailboxDocument,
  MailboxScope,
  PendingAction,
} from './mailbox-document.ts';
import type {
  GmailInvalidPage,
  GmailNotFound,
  SyncFailure,
} from './mailbox-read.ts';
import type { GmailPart } from './message-body.ts';
import type { DraftFile, OutgoingSend } from './outgoing-message.ts';

export type ViewEntry = NonNullable<MailboxDocument['views']>[number];

// A provider's message payload: Gmail's, or Graph's in Gmail's shape with what it knows of its
// attachments and authentication.
export type ProviderPayload = GmailPart &
  Readonly<{
    attachmentsPending?: boolean;
    authentication?: boolean;
  }>;

type ReadFailure = SyncFailure | GmailNotFound | GmailInvalidPage;

// The view state the Inbox store keeps across synchronizations, which a reader advances through.
export type ReaderViews = Readonly<{
  // The document with the next requested view opened, or undefined when none waits.
  opened: (
    document: MailboxDocument,
    historyId?: string,
  ) => MailboxDocument | undefined;
  // Views that could not be read in this synchronization.
  failed: Set<string>;
  // Starts a read whose confirmed deletions search results then drop, unless the mailbox
  // changed meanwhile.
  deletions: () => (ids: ReadonlySet<string>) => void;
}>;

// The step of Historical Metadata Backfill a reader took: the document to commit, the segment
// files it wrote and the segment files the document still names.
export type HistoryStep = Readonly<{
  document: MailboxDocument;
  written: ReadonlyArray<readonly [string, readonly GmailMessage[]]>;
  keep: readonly string[];
}>;

// How the Inbox store reads its mailbox's provider. The store keeps cache publication, reader
// lifetime, prefetch and presentation admission; the reader owns the provider's requests and
// answers.
export interface ProviderReader {
  // The next document to commit, or none when the cache is current.
  readonly advance: (
    scope: MailboxScope,
    document: MailboxDocument | undefined,
    step: number,
  ) => Effect.Effect<Option.Option<MailboxDocument>, ReadFailure>;
  // Whether a saved view is still being listed.
  readonly unfinished: (entry: ViewEntry) => boolean;
  // The new Inbox mail a document `advance` returned brought.
  readonly arrivals: (document: MailboxDocument) => readonly GmailMessage[];
  // The next Historical Metadata Backfill step for a current document, or none.
  readonly history: <E>(
    scope: MailboxScope,
    document: MailboxDocument,
    options: Readonly<{
      done: Set<string>;
      read: (name: string) => Effect.Effect<readonly GmailMessage[], E>;
      newName: Effect.Effect<string>;
    }>,
  ) => Effect.Effect<Option.Option<HistoryStep>, E | ReadFailure>;
  // Whether another store's saved progress matches what this one started from.
  readonly sameProgress: (
    base: MailboxDocument,
    saved: MailboxDocument,
  ) => boolean;
  readonly partData: (
    scope: MailboxScope,
    id: string,
    part: GmailPart,
  ) => Effect.Effect<
    Readonly<{ data: string; size: number | undefined }>,
    SyncFailure | GmailNotFound
  >;
  readonly fullMessage: (
    scope: MailboxScope,
    id: string,
    query: ReadonlyArray<readonly [string, string]>,
  ) => Effect.Effect<ProviderPayload, SyncFailure | GmailNotFound>;
  // A prefetched body's payload, given the payload its preflight read.
  readonly prefetched: (
    scope: MailboxScope,
    id: string,
    preflight: ProviderPayload,
  ) => Effect.Effect<ProviderPayload, SyncFailure | GmailNotFound>;
  // Whether a payload's calendar part is read as an invitation.
  readonly invitations: boolean;
  readonly labels: (
    scope: MailboxScope,
  ) => Effect.Effect<
    Readonly<{ labels: readonly GmailLabel[]; limited: boolean }>,
    ReadFailure
  >;
  readonly readLabels: (
    scope: MailboxScope,
    message: GmailMessage,
  ) => Effect.Effect<
    Option.Option<readonly string[]>,
    SyncFailure | GmailInvalidPage
  >;
  readonly modify: (
    scope: MailboxScope,
    change: PendingAction,
  ) => Effect.Effect<Option.Option<readonly string[]>, SyncFailure>;
  // Whether the provider can make an organizing action.
  readonly offers: (action: GmailAction) => boolean;
  // Whether labels read back show an action the provider made.
  readonly applied: (labels: readonly string[], action: GmailAction) => boolean;
  readonly unavailableActions: () =>
    | ReadonlyArray<GmailAction['kind']>
    | undefined;
  readonly search: (
    scope: MailboxScope,
    request: Readonly<{ query: string; pageToken?: string }>,
    limit: number,
  ) => Effect.Effect<
    Readonly<{ messages: readonly GmailMessage[]; next?: string | undefined }>,
    ReadFailure
  >;
  // Evidence that a message whose handoff had no answer was sent.
  readonly sentCopy: (
    scope: MailboxScope,
    message: Readonly<{ boundary: string; messageId: string | undefined }>,
  ) => Effect.Effect<
    Readonly<{ kind: 'sent'; message: string }> | Readonly<{ kind: 'unknown' }>,
    ReadFailure
  >;
  readonly send: (
    message: OutgoingSend,
    scope: MailboxScope,
  ) => Promise<unknown>;
  // Whether refused authorization of a send means the mailbox's grant was rejected.
  readonly sendRefusalRejectsGrant: boolean;
  // Keeping a message too large for one request as a draft to send, when the provider does.
  readonly prepare?: (
    message: Readonly<{
      segments: OutgoingSend['segments'];
      messageId: string;
      files: readonly DraftFile[];
    }>,
    scope: MailboxScope,
  ) => Promise<unknown>;
  readonly discard?: (
    messageId: string,
    scope: MailboxScope,
  ) => Promise<unknown>;
  // Creating a label, when the provider does.
  readonly createLabel?: (
    scope: MailboxScope,
    name: string,
  ) => Effect.Effect<Option.Option<GmailLabel>, SyncFailure>;
  // A message from anywhere in the mailbox, when the provider looks one up by ID.
  readonly message?: (
    scope: MailboxScope,
    id: string,
  ) => Effect.Effect<GmailMessage | undefined, SyncFailure | GmailInvalidPage>;
}
