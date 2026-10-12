import * as Schema from 'effect/Schema';

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
