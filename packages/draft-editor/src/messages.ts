import type {
  Asset,
  ImageWidth,
  Selection,
  SemanticDocument,
  TableDocument,
} from '@private-email/mail-core/semantic-document';

import {
  AssetSchema,
  BlockKindSchema,
  imagesOf,
  MarkSchema,
  TableDocumentSchema,
  withImage,
  withoutImage,
} from '@private-email/mail-core/semantic-document';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

const Offset = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0));

// The page's messages. After every edit or selection change it reports the formatting at the
// selection, and the body and Attachments when they changed; `revision` counts its body edits. A
// paste or drop carrying files asks the host to read the pasteboard instead: the page never reads
// them. While the host's Slash Command Menu shows, the keys that drive it reach the host instead of the
// body.
const PageMessageSchema = Schema.fromJsonString(
  Schema.Union([
    Schema.Struct({
      type: Schema.Literal('update'),
      revision: Offset,
      // The page is read-only and has flushed every preceding edit before the host finishes.
      frozen: Schema.optionalKey(Schema.Literal(true)),
      document: Schema.optionalKey(TableDocumentSchema),
      attachments: Schema.optionalKey(Schema.Array(AssetSchema)),
      // Display offsets, as the current composer counts them: blocks joined by line breaks, list
      // items after their shown marker.
      selection: Schema.Struct({ start: Offset, end: Offset }),
      marks: Schema.Array(MarkSchema),
      kind: BlockKindSchema,
      undo: Schema.Boolean,
      redo: Schema.Boolean,
      // An Undo or Redo made this edit, not typing.
      restored: Schema.optionalKey(Schema.Literal(true)),
      // The host's replacement computed from this revision made this edit.
      replaced: Schema.optionalKey(Offset),
      // The caret's line in the page's viewport, while that line starts with `/`, for the Slash
      // Command Menu to hang from.
      caret: Schema.optionalKey(
        Schema.Struct({ top: Schema.Finite, bottom: Schema.Finite }),
      ),
    }),
    Schema.Struct({ type: Schema.Literal('paste') }),
    Schema.Struct({ type: Schema.Literal('drop') }),
    Schema.Struct({
      type: Schema.Literal('key'),
      key: Schema.Literals(['Enter', 'Tab', 'ArrowUp', 'ArrowDown', 'Escape']),
    }),
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
  // Ends editing in the page, which hides the software keyboard, or resumes it at the selection.
  | Readonly<{ type: 'blur' }>
  | Readonly<{ type: 'focus' }>
  | Readonly<{ type: 'editable'; editable: boolean }>
  // Whether the Slash Command Menu shows, so the page hands its keys to the host.
  | Readonly<{ type: 'menu'; open: boolean }>
  | Readonly<{
      type: 'replace';
      revision: number;
      document: TableDocument;
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
  // One undoable edit: every use of an Inline Image shows at a display width, or with null at its
  // original size.
  | Readonly<{ type: 'resize'; id: string; width: ImageWidth | null }>
  // Verified native thumbnails; null revokes bytes that are no longer available or verified.
  | Readonly<{
      type: 'previews';
      previews: Readonly<Record<string, string | null>>;
    }>;

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
