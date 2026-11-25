---
'@private-email/draft-editor': minor
'@private-email/mail-core': minor
'@private-email/macos': patch
'@private-email/mobile': patch
---

The Tiptap Draft editor page keeps a Draft's alignment, list levels, text colors, backgrounds,
font families and sizes through opening, editing and saving, and shows them as the current
composer does, with Dark colors and per-level list numbering. Typing, Return, joined blocks, marks
and block kinds keep them; pasted HTML still carries none. mail-core's new `body-display` entry
point holds `formatStyleOf`, `isListKind`, `listNumbersOf` and `markersOf` without a schema
library, so the page can bundle them; `semantic-document` still exports the first three (#2884).
