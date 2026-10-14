import type {
  Asset,
  Selection,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';

import {
  AssetSchema,
  BlockKindSchema,
  imagesOf,
  MarkSchema,
  SemanticDocumentSchema,
  withImage,
  withoutImage,
} from '@private-email/mail-core/semantic-document';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

const Offset = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0));

// The page's messages. After every edit or selection change it reports the formatting at the
// selection, and the body and Attachments when they changed; `revision` counts its body edits. A
// paste carrying files asks the host to read the pasteboard instead: the page never reads them.
const PageMessageSchema = Schema.fromJsonString(
  Schema.Union([
    Schema.Struct({
      type: Schema.Literal('update'),
      revision: Offset,
      document: Schema.optionalKey(SemanticDocumentSchema),
      attachments: Schema.optionalKey(Schema.Array(AssetSchema)),
      // Display offsets, as the current composer counts them: blocks joined by line breaks, list
      // items after their shown marker.
      selection: Schema.Struct({ start: Offset, end: Offset }),
      marks: Schema.Array(MarkSchema),
      kind: BlockKindSchema,
      undo: Schema.Boolean,
      redo: Schema.Boolean,
    }),
    Schema.Struct({ type: Schema.Literal('paste') }),
  ]),
);
export type PageMessage = typeof PageMessageSchema.Type;
export type Update = Extract<PageMessage, { type: 'update' }>;

// The page message, or undefined for any malformed message.
export const decodeMessage = (message: string) =>
  Option.getOrUndefined(Schema.decodeOption(PageMessageSchema)(message));

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
      document: SemanticDocument;
      selection: Selection;
    }>
  // One undoable edit: the images go inline at the selection, the rest become Attachments.
  | Readonly<{
      type: 'add';
      images: readonly Asset[];
      attachments: readonly Asset[];
    }>
  // One undoable edit each: removes every use of an asset, or turns an Inline Image into an
  // Attachment and an Attachment into an Inline Image at the selection.
  | Readonly<{ type: 'remove'; id: string }>
  | Readonly<{ type: 'convert'; id: string }>
  // Thumbnails native code made from verified bytes: the only image data the page receives.
  | Readonly<{ type: 'previews'; previews: Readonly<Record<string, string>> }>;

// The script that runs a command in the page; the page defines `draftCommand`.
export const commandScript = (command: Command) =>
  `globalThis.draftCommand?.(${JSON.stringify(command)}); true;`;

// The body and Attachments the page reported, holding only assets the host gave it, as the host
// knows them now: the page cannot name bytes it was never given, and an import that completed
// since the page received its asset stays complete.
export const knownAssets = (
  known: ReadonlyMap<string, Asset>,
  {
    document,
    attachments,
  }: Readonly<{
    document: SemanticDocument;
    attachments: readonly Asset[];
  }>,
) => ({
  body: imagesOf(document).reduce((body, { id }) => {
    const asset = known.get(id);
    return asset === undefined
      ? withoutImage(body, id)
      : withImage(body, id, () => asset);
  }, document),
  attachments: attachments.flatMap(({ id }) => {
    const asset = known.get(id);
    return asset === undefined ? [] : [asset];
  }),
});
