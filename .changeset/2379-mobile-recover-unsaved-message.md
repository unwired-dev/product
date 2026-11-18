---
'@private-email/mobile': minor
---

iPhone and iPad offer each unsaved message the previous run kept (#2379, part of #1989).

- Once the Drafts open after a relaunch, and while no composer is open, the app asks **Recover unsaved message?** in a system alert for each composer recovery record the previous run left in the shown Mail Profile. **Restore** opens the composer on the recovered version, which Close then asks to save; **Discard** removes the record unless a composer has the Draft open, and keeps the stored Draft as it was. Records this run writes are never offered.
