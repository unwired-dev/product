---
'@private-email/draft-editor': minor
'@private-email/localization': patch
'@private-email/mobile': patch
'@private-email/macos': patch
'@private-email/mail-core': patch
---

Open Drafts with Inline Images and Attachments in the registration-draft-editor Tiptap evaluation editor, now laid out as the approved compose design: the current composer's header, sending mailbox, Subject, To, Cc and Bcc and Send around the page's body. iPhone formats from a floating Liquid Glass pill and a Format panel that replaces the keyboard, iPad and Mac keep the format bar, and Writing tools gather Rewrite, Translate and Suggest reply. Nothing is saved until Save Draft (Save on Mac) or Send; Close offers Delete Draft and Save Draft on iPhone and iPad, and the Mac asks whether to save. Images placed inline through the system pickers (and, on iPhone and iPad, Paste Image or a paste into the page) keep their Draft Asset identity through typing, moving, deletion, Undo, Redo, saving and reopening; a row's context menu turns an Inline Image into an Attachment or an image Attachment into an Inline Image as one undoable edit. The page receives only native thumbnails of verified bytes and refuses pasted or dropped files. Production and other scenarios retain the current composer.

The draft-editor message API replaces `decodeUpdate` with `decodeMessage`, which also decodes the page's `paste` request; `update` messages carry the Draft's Attachments, the page accepts `add`, `remove`, `convert`, `previews`, `focus` and `editable` commands, and `knownAssets` keeps a reported body to the assets the host gave the page. `supported` is removed. Close, Save and Send wait for a read-only page acknowledgement so queued body edits are included; import settlement keeps the saved baseline current, and navigation resumes after Save or Delete.

The Mac save question keeps background composer controls inactive and hidden from assistive technology, with keyboard focus retained in its choices until Save, Don’t Save or Cancel.
