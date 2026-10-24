import * as DateTime from 'effect/DateTime';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

// Persisted synchronization times must be parseable before newMailSince uses them.
export const SynchronizationTime = Schema.String.check(
  Schema.makeFilter((value) => Option.isSome(DateTime.make(value))),
);

// Graph's message, attachment and folder IDs also admit Gmail's alphanumeric IDs.
export const GraphId = Schema.String.check(
  Schema.isPattern(/^[\w=-]{1,512}$/u),
);

export const GmailMessageSchema = Schema.Struct({
  // A Gmail or Microsoft Graph message ID, unique within its mailbox.
  id: GraphId,
  threadId: Schema.String,
  sender: Schema.String,
  address: Schema.String,
  subject: Schema.String,
  preview: Schema.String,
  receivedAt: Schema.String,
  unread: Schema.Boolean,
  // Provider placement and read-state labels; absent in older caches, which are listed again.
  labels: Schema.optionalKey(Schema.Array(Schema.String)),
});
export type GmailMessage = typeof GmailMessageSchema.Type;

// The earliest receipt that can still be new mail after the synchronization that began at
// `synchronizedAt`, an ISO instant on this device's clock; provider clocks may run up to five
// minutes behind it. Caches saved before they recorded it fall back to their newest message.
export const newMailSince = (
  synchronizedAt: string | undefined,
  cached: ReadonlyArray<Readonly<{ receivedAt: string }>>,
) =>
  synchronizedAt === undefined
    ? cached.reduce(
        (latest, { receivedAt }) => (receivedAt > latest ? receivedAt : latest),
        '',
      )
    : DateTime.formatIso(
        DateTime.subtract(DateTime.makeUnsafe(synchronizedAt), { minutes: 5 }),
      );
