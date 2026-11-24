---
'@private-email/mail-core': minor
'@private-email/mobile': patch
'@private-email/macos': patch
---

Drafts now keep tables, with their header cells, merged cells and formatted cell
text, through saving and reopening. The composers do not show a table yet, but
editing a Draft's text, subject or recipients no longer removes it, and sent mail
writes header cells as table headers.

In mail-core, `DraftSchema.body` is a `TableDocument`; `textOf` gives the text a
composer edits and `withText` writes an edit back without removing the tables.
