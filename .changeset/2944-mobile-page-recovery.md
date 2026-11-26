---
'@private-email/mobile': patch
---

On iPhone and iPad, the Draft editor page of `registration-draft-editor` builds keeps unsaved
edits in a composer recovery record, as the current composer does, and **Restore** after the app
ends reopens them in the page instead of the current composer (#2944).
