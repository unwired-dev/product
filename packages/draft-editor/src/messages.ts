import type { Selection } from '@private-email/mail-core/semantic-document';

import {
  BlockKindSchema,
  MarkSchema,
  SemanticDocumentSchema,
} from '@private-email/mail-core/semantic-document';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

const Offset = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0));

// The page's only message, after every edit or selection change: the formatting at the
// selection, and the whole body when it changed. `revision` counts the page's body edits.
const UpdateMessage = Schema.fromJsonString(
  Schema.Struct({
    type: Schema.Literal('update'),
    revision: Offset,
    document: Schema.optionalKey(SemanticDocumentSchema),
    // Display offsets, as the current composer counts them: blocks joined by line breaks, list
    // items after their shown marker.
    selection: Schema.Struct({ start: Offset, end: Offset }),
    marks: Schema.Array(MarkSchema),
    kind: BlockKindSchema,
    undo: Schema.Boolean,
    redo: Schema.Boolean,
  }),
);
export type Update = typeof UpdateMessage.Type;

// The page state a message carries, or undefined for any malformed message.
export const decodeUpdate = (message: string) =>
  Option.getOrUndefined(Schema.decodeOption(UpdateMessage)(message));

// What the host asks the page to do. A replacement applies only to the body revision it was
// computed from, as one undoable edit.
export type Command =
  | Readonly<{ type: 'mark'; mark: typeof MarkSchema.Type }>
  | Readonly<{ type: 'block'; kind: typeof BlockKindSchema.Type }>
  | Readonly<{ type: 'undo' }>
  | Readonly<{ type: 'redo' }>
  // Ends editing in the page, which hides the software keyboard.
  | Readonly<{ type: 'blur' }>
  | Readonly<{
      type: 'replace';
      revision: number;
      document: typeof SemanticDocumentSchema.Type;
      selection: Selection;
    }>;

// The script that runs a command in the page; the page defines `draftCommand`.
export const commandScript = (command: Command) =>
  `globalThis.draftCommand?.(${JSON.stringify(command)}); true;`;
