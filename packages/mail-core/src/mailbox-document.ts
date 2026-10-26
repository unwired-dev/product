import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';
import * as Schema from 'effect/Schema';

import type { GmailMessage } from './mailbox-message.ts';

import { GmailActionSchema, GmailLabelSchema } from './gmail-actions.ts';
import { GmailMessageSchema } from './mailbox-message.ts';
import { GraphDeltaLink } from './microsoft-graph.ts';

export type { GmailMessage } from './mailbox-message.ts';

// The newest messages each view keeps in this document; Gmail's older mail is kept in history
// segments, which commits only write when they change.
export const cacheLimit = 200;
// The ordinary Gmail view budget; active windows protect their views, growing it when needed.
export const cachedViews = 8;
export const GmailId = Schema.String.check(Schema.isPattern(/^[0-9A-Za-z]+$/u));
export const HistoryId = Schema.String.check(Schema.isPattern(/^\d+$/u));

// A requested change Gmail has not confirmed, with the message as it was shown, so restoring a
// message that already left the cache can show it again.
const PendingActionSchema = Schema.Struct({
  id: Schema.optionalKey(Schema.NonEmptyString),
  attempts: Schema.optionalKey(
    Schema.Array(
      Schema.Struct({ id: Schema.NonEmptyString, at: Schema.Finite }),
    ),
  ),
  retryFrom: Schema.optionalKey(
    Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  ),
  // Gmail refused this change for good; only its current labels remain to be read.
  refused: Schema.optionalKey(Schema.Literal(true)),
  action: GmailActionSchema,
  message: GmailMessageSchema,
});
export type PendingAction = typeof PendingActionSchema.Type;

// One Historical Metadata Backfill pass over All Mail: each listed page is its own encrypted
// segment file, named here, newest page first.
const HistoryPassSchema = Schema.Struct({
  segments: Schema.Array(
    Schema.Struct({
      name: Schema.String.check(Schema.isPattern(/^[0-9a-z]{1,32}$/u)),
      count: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
    }),
  ),
  pageToken: Schema.optionalKey(Schema.String),
  complete: Schema.optionalKey(Schema.Literal(true)),
});
export type HistoryPass = typeof HistoryPassSchema.Type;

const MailboxHistorySchema = Schema.Struct({
  // Gmail's message count when the pass began, for progress.
  total: Schema.optionalKey(Schema.Int.check(Schema.isGreaterThanOrEqualTo(0))),
  current: HistoryPassSchema,
  // The last pass, still shown while a pass after an expired history ID lists everything again.
  previous: Schema.optionalKey(HistoryPassSchema),
  // Changes before a reconciling pass began stay visible with the old pass, then retire together.
  reconcilingThrough: Schema.optionalKey(
    Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  ),
  // Messages Gmail changed since their segment was written, newest last; an absent message left
  // All Mail. Reads apply them over the segments until a fold writes them in.
  changes: Schema.Array(
    Schema.Struct({
      id: GmailId,
      message: Schema.optionalKey(GmailMessageSchema),
    }),
  ),
  // A fold in progress: changes before `through` are written into segments before `segment`;
  // `found` names those already written, and `newest` is the pass's newest receipt.
  folding: Schema.optionalKey(
    Schema.Struct({
      segment: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
      through: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
      found: Schema.Array(GmailId),
      newest: Schema.optionalKey(Schema.String),
    }),
  ),
});
export type MailboxHistory = typeof MailboxHistorySchema.Type;

// A history segment's messages, in listing order.
const SegmentSchema = Schema.fromJsonString(Schema.Array(GmailMessageSchema));
export const decodeSegment = Schema.decodeUnknownEffect(SegmentSchema);
export const encodeSegment = Schema.encodeEffect(SegmentSchema);

const GraphCheckpointSchema = Schema.Union([
  // A Microsoft folder, listed before its delta round: the round runs from the first page, or
  // resumes at `link`, and the folder is listed again when it ends.
  Schema.Struct({
    kind: Schema.Literal('graph-listing'),
    link: Schema.optionalKey(GraphDeltaLink),
  }),
  // Graph's link to the changes after the last applied delta page.
  Schema.Struct({
    kind: Schema.Literal('graph-current'),
    link: GraphDeltaLink,
    // An action shortened the full cache, whose oldest receipt this was; the next delta page
    // refills it while the cache still counts as full.
    refillUntil: Schema.optionalKey(Schema.String),
  }),
]);

// The checkpoint is committed with the messages it produced, so a restart repeats no step twice.
const MailboxDocumentSchema = Schema.Struct({
  version: Schema.Literal(1),
  messages: Schema.Array(GmailMessageSchema),
  // The latest Gmail history already considered for notifications, independent of view replay.
  notificationHistoryId: Schema.optionalKey(HistoryId),
  // Provider-confirmed messages stay in `messages`; requested changes wait here, in order.
  pending: Schema.optionalKey(Schema.Array(PendingActionSchema)),
  // The mailbox's own labels, for labeling and moving, or its folders for moving.
  labels: Schema.optionalKey(Schema.Array(GmailLabelSchema)),
  // More folders exist than were listed.
  labelsLimited: Schema.optionalKey(Schema.Literal(true)),
  // Views other than the Inbox that a reader opened, most recently opened first. Each keeps its
  // newest messages; a Gmail mailbox's history keeps them current from the same checkpoint, and
  // each Microsoft folder from its own.
  views: Schema.optionalKey(
    Schema.Array(
      Schema.Struct({
        // A label or folder ID, or a system view such as All Mail or Trash.
        label: Schema.String,
        messages: Schema.Array(GmailMessageSchema),
        // Present while the view is listed from its first page, as for the Inbox's backfill.
        listing: Schema.optionalKey(
          Schema.Struct({
            historyId: HistoryId,
            pageToken: Schema.optionalKey(Schema.String),
            seen: Schema.Array(GmailId),
          }),
        ),
        // A Microsoft folder's own delta checkpoint, absent until its first listing.
        checkpoint: Schema.optionalKey(GraphCheckpointSchema),
      }),
    ),
  ),
  // Gmail's Historical Metadata Backfill, absent until the Inbox is current.
  history: Schema.optionalKey(MailboxHistorySchema),
  checkpoint: Schema.Union([
    // Listing the Inbox from the history ID read before the first page; `seen` survives an
    // interruption so a replacement listing can drop messages that left the Inbox.
    Schema.Struct({
      kind: Schema.Literal('backfill'),
      historyId: HistoryId,
      pageToken: Schema.optionalKey(Schema.String),
      seen: Schema.Array(GmailId),
    }),
    Schema.Struct({ kind: Schema.Literal('current'), historyId: HistoryId }),
    ...GraphCheckpointSchema.members,
  ]),
});
export type MailboxDocument = typeof MailboxDocumentSchema.Type;
export const sameCheckpoint = Schema.toEquivalence(
  MailboxDocumentSchema.fields.checkpoint,
);
export const sameHistory = Schema.toEquivalence(
  Schema.UndefinedOr(MailboxHistorySchema),
);
// Graph folders advance independently of the Inbox, including opening or retiring a saved view.
export const sameGraphViews = Schema.toEquivalence(
  Schema.Array(
    Schema.Struct({
      label: Schema.String,
      checkpoint: Schema.optionalKey(GraphCheckpointSchema),
    }),
  ),
);
export const decodeDocument = Schema.decodeUnknownEffect(
  Schema.fromJsonString(MailboxDocumentSchema),
);
export const encodeDocument = Schema.encodeEffect(
  Schema.fromJsonString(MailboxDocumentSchema),
);

const CacheSchema = Schema.Struct({
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  address: Schema.NonEmptyString,
  generation: Schema.NonEmptyString,
  owner: Schema.optionalKey(Schema.NonEmptyString),
  document: Schema.NullOr(Schema.String),
  availability: Schema.optionalKey(Schema.Literal('retry')),
});
export type Cache = typeof CacheSchema.Type;
export type MailboxScope = Pick<Cache, 'address' | 'generation' | 'owner'>;
export const decodeCache = Schema.decodeUnknownEffect(CacheSchema);
export const sameMailbox = (left: MailboxScope, right: MailboxScope) =>
  left.address === right.address &&
  (left.owner !== undefined && right.owner !== undefined
    ? left.owner === right.owner
    : left.generation === right.generation);

export const newestFirst = Order.flip(
  Order.combine(
    Order.mapInput(Order.String, (message: GmailMessage) => message.receivedAt),
    Order.mapInput(Order.String, (message: GmailMessage) => message.id),
  ),
);

// Applies changes by message ID, so repeating a step never duplicates a message.
export const merge = (
  messages: readonly GmailMessage[],
  // Messages no longer in the Inbox are undefined.
  found: ReadonlyArray<readonly [string, GmailMessage | undefined]>,
  deleted: ReadonlySet<string> = new Set(),
) => {
  const byId = new Map(messages.map((message) => [message.id, message]));
  for (const id of deleted) {
    byId.delete(id);
  }
  for (const [id, message] of found) {
    if (message === undefined) {
      byId.delete(id);
    } else {
      byId.set(id, message);
    }
  }
  return Arr.sort(byId.values(), newestFirst);
};
