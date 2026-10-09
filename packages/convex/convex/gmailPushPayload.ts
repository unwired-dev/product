import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

const GmailMinimalPushMetadataSchema = Schema.Struct({
  emailAddress: Schema.NonEmptyString,
  historyId: Schema.NonEmptyString,
});
export type GmailMinimalPushMetadata =
  typeof GmailMinimalPushMetadataSchema.Type;

// Pub/Sub encodes message data as base64; URL-safe encoding is accepted too.
const decodePubSubEnvelope = Schema.decodeUnknownOption(
  Schema.Struct({
    message: Schema.Struct({
      data: Schema.Union([
        Schema.StringFromBase64,
        Schema.StringFromBase64Url,
      ]).pipe(
        Schema.decodeTo(Schema.fromJsonString(GmailMinimalPushMetadataSchema)),
      ),
    }),
  }),
);

export function decodeGmailPushEnvelope(
  envelope: unknown,
): GmailMinimalPushMetadata {
  return Option.getOrThrowWith(
    decodePubSubEnvelope(envelope),
    () => new Error('Invalid Gmail push metadata'),
  ).message.data;
}

export function gmailWakeupPayload(
  historyId: string,
  routeId: string,
): Readonly<{
  aps: Readonly<{ 'content-available': 1 }>;
  historyId: string;
  provider: 'gmail';
  routeId: string;
}> {
  return {
    aps: { 'content-available': 1 },
    historyId,
    provider: 'gmail',
    routeId,
  };
}
