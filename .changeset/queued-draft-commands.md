---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Discard the editor's own Draft after earlier autosaves finish, including when a
conflict moves it to another copy. Keep repeated Undo and Redo commands advancing
one step each before the composer redraws. The Draft store's discard action also
accepts a target resolver for editors whose identity can change while saving.
