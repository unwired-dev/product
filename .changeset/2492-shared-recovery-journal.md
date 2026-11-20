---
'@private-email/mobile': patch
'@private-email/macos': patch
'@private-email/mail-core': patch
---

iPhone, iPad and Mac composers share one composer recovery journal from mail-core (#2492).

- mail-core adds the `recovery-journal` entry point: `createRecoveryJournal` keeps an open composer's unsaved version in its recovery record two seconds after an edit and on return to the foreground, through an Effect-managed wait that disposing the composer cancels.
- Recording, removal retries and Mac Quit waiting for removal behave as before.
