import * as Schema from 'effect/Schema';

// The AppKit presenter answers with an item key, or null when dismissed.
export const isMenuChoice = Schema.is(Schema.NullOr(Schema.String));

// An alert sheet answers with its chosen button's index, or null once withdrawn.
export const isAlertChoice = Schema.is(Schema.NullOr(Schema.Int));

// An alert sheet with a text field also answers with the field's text.
export const isTextChoice = Schema.is(
  Schema.NullOr(Schema.Struct({ index: Schema.Int, text: Schema.String })),
);
