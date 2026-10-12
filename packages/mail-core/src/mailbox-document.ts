import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';
import * as Schema from 'effect/Schema';

import type { GmailMessage } from './mailbox-message.ts';

import { GmailActionSchema, GmailLabelSchema } from './gmail-actions.ts';
import { GmailMessageSchema } from './mailbox-message.ts';
import { GraphDeltaLink } from './microsoft-graph.ts';

export type { GmailMessage } from './mailbox-message.ts';

// ponytail: the newest Inbox messages kept on this device; older ones stay at the provider. Each commit
// rewrites the whole document, so complete Historical Metadata Backfill needs an indexed store.
export const cacheLimit = 200;
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

// The checkpoint is committed with the messages it produced, so a restart repeats no step twice.
const MailboxDocumentSchema = Schema.Struct({
  version: Schema.Literal(1),
  messages: Schema.Array(GmailMessageSchema),
  // Provider-confirmed messages stay in `messages`; requested changes wait here, in order.
  pending: Schema.optionalKey(Schema.Array(PendingActionSchema)),
  // The mailbox's own labels, for labeling and moving, or its folders for moving.
  labels: Schema.optionalKey(Schema.Array(GmailLabelSchema)),
  // More folders exist than were listed.
  labelsLimited: Schema.optionalKey(Schema.Literal(true)),
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
    // A Microsoft Inbox, listed before its delta round: the round runs from the first page, or
    // resumes at `link`, and the Inbox is listed again when it ends.
    Schema.Struct({
      kind: Schema.Literal('graph-listing'),
      link: Schema.optionalKey(GraphDeltaLink),
    }),
    // Graph's link to the changes after the last applied delta page.
    Schema.Struct({
      kind: Schema.Literal('graph-current'),
      link: GraphDeltaLink,
    }),
  ]),
});
export type MailboxDocument = typeof MailboxDocumentSchema.Type;
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
