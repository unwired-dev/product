---
'@private-email/draft-editor': minor
'@private-email/localization': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Open Drafts with Inline Images and Attachments in the registration-draft-editor Tiptap evaluation editor. Images placed inline through the system pickers (and, on iPhone and iPad, Paste Image or a paste into the page) keep their Draft Asset identity through typing, moving, deletion, Undo, Redo, saving and reopening; files and Attachments are listed under the body, and an explicit action turns an Inline Image into an Attachment or an image Attachment into an Inline Image as one undoable edit. The page receives only native thumbnails of verified bytes and refuses pasted or dropped files. Production and other scenarios retain the current composer.

The draft-editor message API replaces `decodeUpdate` with `decodeMessage`, which also decodes the page's `paste` request; `update` messages carry the Draft's Attachments, the page accepts `add`, `remove`, `convert` and `previews` commands, and `knownAssets` keeps a reported body to the assets the host gave the page. `supported` is removed.
