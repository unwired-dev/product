---
'@private-email/localization': patch
'@private-email/macos': minor
---

The Mac offers each unsaved message the previous run kept (#2329, part of #1989).

- Once the Drafts open after a relaunch, an Inbox window asks **Recover unsaved message?** for each composer recovery record the previous run left. **Restore** opens the composer on the recovered version, which Close then asks to save; **Discard** removes the record and keeps the stored Draft. Records written during this run are never offered.
