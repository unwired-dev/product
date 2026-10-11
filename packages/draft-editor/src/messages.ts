import { SemanticDocumentSchema } from '@private-email/mail-core/semantic-document';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

// The page's only message: the whole body after an edit. Hosts accept nothing else.
const Change = Schema.fromJsonString(
  Schema.Struct({
    type: Schema.Literal('change'),
    document: SemanticDocumentSchema,
  }),
);

// The edited body a page message carries, or undefined for any malformed message.
export const decodeChange = (message: string) =>
  Option.getOrUndefined(Schema.decodeOption(Change)(message))?.document;
