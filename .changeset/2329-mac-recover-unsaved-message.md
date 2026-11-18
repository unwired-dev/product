---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/macos': minor
---

The Mac offers each unsaved message the previous run kept (#2329, part of #1989).

- Once the Drafts open after a relaunch, an Inbox window asks **Recover unsaved message?** for each composer recovery record the previous run left. **Restore** opens the composer on the recovered version, which Close then asks to save; **Discard** removes the record unless another composer has the Draft open, and keeps the stored Draft as it was. Records this run writes after the account's first Inbox window opens are never offered.
- `@private-email/mail-core/drafts` exports `sameContent`, so a client can tell whether a composer recovery record changed since it was read.
