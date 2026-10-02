import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

const GmailMinimalPushMetadataSchema = Schema.Struct({
  emailAddress: Schema.NonEmptyString,
  historyId: Schema.NonEmptyString,
});
export type GmailMinimalPushMetadata =
  typeof GmailMinimalPushMetadataSchema.Type;

const decodePubSubEnvelope = Schema.decodeUnknownOption(
  Schema.Struct({ message: Schema.Struct({ data: Schema.String }) }),
);
const decodeGmailMinimalPushMetadata = Schema.decodeUnknownOption(
  Schema.fromJsonString(GmailMinimalPushMetadataSchema),
);

export function decodeGmailPushEnvelope(
  envelope: unknown,
): GmailMinimalPushMetadata {
  const { data } = Option.getOrThrowWith(
    decodePubSubEnvelope(envelope),
    () => new TypeError('Gmail push data required'),
  ).message;

  const base64 = data
    .replaceAll('-', '+')
    .replaceAll('_', '/')
    .padEnd(Math.ceil(data.length / 4) * 4, '=');
  const metadataJson = new TextDecoder().decode(
    Uint8Array.from(atob(base64), (character) => character.codePointAt(0) ?? 0),
  );
  return Option.getOrThrowWith(
    decodeGmailMinimalPushMetadata(metadataJson),
    () => new Error('Invalid Gmail push metadata'),
  );
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
