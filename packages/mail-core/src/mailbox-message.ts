import * as Schema from 'effect/Schema';

import { GraphId } from './microsoft-graph.ts';

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
  // Gmail's label IDs; absent in caches written before organizing, which are listed again, and
  // for Microsoft mail, which offers no organizing actions yet.
  labels: Schema.optionalKey(Schema.Array(Schema.String)),
});
export type GmailMessage = typeof GmailMessageSchema.Type;
