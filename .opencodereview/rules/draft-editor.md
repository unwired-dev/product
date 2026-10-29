Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to the packaged Draft editor.

#### Editor-library behavior matches the composer contract

- A link mark in `packages/draft-editor/src/editor.ts` relying only on
  `inclusive: false` to match the shared document's editing rules. Check Return
  followed by typing at the new link edge, and replacement selections that start
  linked and end outside that link, against `semantic-document.ts`'s `splice`.
  Tiptap can carry a split link into stored typing marks, while ProseMirror's
  `marksAcross` can discard the first replaced character's link. Exercise the
  real key and text-input handlers with Undo/Redo, or the editor can silently
  extend a link at its edge or drop it from replacement text.

- An `editable: false` acknowledgement in `packages/draft-editor/src/editor.ts`
  that stops typing but still permits mutating `draftCommand` calls. Native
  toolbar or context-menu callbacks may already be queued; keep the acknowledged
  document unchanged until editing resumes, while allowing verified thumbnail
  updates. Otherwise a late Undo or conversion can diverge from the host's saved
  version, including after a refused save.

- A key handler in `packages/draft-editor/src/editor.ts` delegating to a library command without checking its fallthrough behavior against `docs/drafts.md` and the current composer's `createdKind`/`continuation` in `packages/mail-core/src/semantic-document.ts`. In particular, Return must continue bulleted and numbered list items and quote lines even when empty; check the resulting semantic body, caret for subsequent typing and one-step Undo/Redo. Otherwise the library's empty-block exit can silently save a paragraph instead of another item or quote line.
