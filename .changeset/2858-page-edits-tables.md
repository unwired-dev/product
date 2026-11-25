---
'@private-email/draft-editor': minor
'@private-email/mobile': patch
'@private-email/macos': patch
---

The Tiptap Draft editor page edits a Draft's tables: Tab and Shift-Tab move
between cells, Tab leaves the last cell without adding a row, Return adds a line
in a cell, Backspace after a table selects it and a second deletes it as one Undo
step, and the caret's cell is outlined. A table the page cannot edit unchanged is
kept as it is. The composers still give the page the Draft's text without its
tables.

The page's `draftEditor.document`, its `update` message's `document` and the
`replace` command now carry a `TableDocument`.
