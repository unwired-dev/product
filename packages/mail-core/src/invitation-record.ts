import * as Schema from 'effect/Schema';

// An Invitation Response this device sent, or may have sent, for one revision of an invitation,
// with the time it answered so a later revision can say what changed; older records lack it.
// `recurrence` names one meeting of a series by its RECURRENCE-ID instant.
// `boundary` finds an unconfirmed send in Sent.
const InvitationTime = Schema.Struct({
  at: Schema.Finite,
  allDay: Schema.Boolean,
});
const InvitationRevision = {
  uid: Schema.String,
  sequence: Schema.Int,
  recurrence: Schema.optionalKey(Schema.Finite),
  choice: Schema.Literals(['accepted', 'tentative', 'declined']),
  start: Schema.optionalKey(InvitationTime),
  end: Schema.optionalKey(InvitationTime),
  // The received message that carried the revision; records saved before it was kept have none.
  message: Schema.optionalKey(Schema.String),
};
export const InvitationResponseSchema = Schema.Union([
  Schema.Struct({
    kind: Schema.Literal('sent'),
    ...InvitationRevision,
    at: Schema.Finite,
  }),
  Schema.Struct({
    kind: Schema.Literal('unknown'),
    ...InvitationRevision,
    boundary: Schema.String,
  }),
]);
export type InvitationResponse = typeof InvitationResponseSchema.Type;

// The Invitation Response an Outbox message carries: the revision it answers, the choice, the
// received message and the meeting's title.
export const InvitationAnswerSchema = Schema.Struct({
  ...InvitationRevision,
  message: Schema.String,
  summary: Schema.optionalKey(Schema.String),
});
export type InvitationAnswer = typeof InvitationAnswerSchema.Type;

// `responses` with `response` in place of any record of the same revision, or without one.
export const withResponse = (
  responses: readonly InvitationResponse[] | undefined,
  revision: Readonly<
    Pick<InvitationResponse, 'uid' | 'sequence' | 'recurrence'>
  >,
  response: InvitationResponse | undefined,
) => [
  ...(response === undefined ? [] : [response]),
  ...(responses ?? []).filter(
    ({ uid, sequence, recurrence }) =>
      uid !== revision.uid ||
      sequence !== revision.sequence ||
      recurrence !== revision.recurrence,
  ),
];
