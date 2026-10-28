---
'@private-email/mail-core': minor
---

Keep the bodies of older Gmail messages opened from downloaded history, so they reopen offline after a relaunch (#1385).

- **Kept with history:** opening a message revealed from downloaded history saves its body in the Bounded Encrypted Body Cache, within the same budget, eviction order and working-set protection as other opened bodies. The mailbox document names those bodies, so pruning no longer removes them for being outside the recent cached views.
- **Removed with the message:** the body leaves the device when Gmail reports the message deleted or outside All Mail, or when a new pass after an expired history ID completes without listing it.
