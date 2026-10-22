import * as Schema from 'effect/Schema';

// The AppKit presenter answers with an item key, or null when dismissed.
export const isMenuChoice = Schema.is(Schema.NullOr(Schema.String));
