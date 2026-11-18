---
'@private-email/mobile': patch
'@private-email/macos': patch
'@private-email/mail-core': patch
---

Composer recovery waits for a pending New Message and tries a refused record removal again (#2381, part of #1989).

- iPhone and iPad no longer ask **Recover unsaved message?** while a new Draft is being created, so **Restore** cannot open a composer that the new message then replaces. The record is offered once that composer closes.
- On iPhone, iPad and Mac, an open composer keeps a recovery record it could not remove and removes it with the next write. A removal that finishes after newer edits were journaled leaves their record in place.
