---
'@private-email/draft-editor': minor
'@private-email/localization': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Extend the registration-draft-editor Tiptap evaluation editor to formatted Drafts: headings, lists, quotes, code and inline marks with Markdown shortcuts, word-step Undo and Redo, an explicit paste policy, and reviewed rewrites, reply suggestions and translations applied as one page edit. Production and other scenarios retain the current composer.

Return continues bulleted and numbered lists and quotes even on an empty item or line.

The draft-editor message API replaces `decodeChange` and `change` messages with `decodeUpdate` and revisioned `update` messages carrying selection and formatting state.
