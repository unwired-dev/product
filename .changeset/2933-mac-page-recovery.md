---
'@private-email/macos': patch
---

On Mac, the Draft editor page of `registration-draft-editor` builds keeps unsaved edits in a
composer recovery record, as the current composer does, and **Restore** after a force quit
reopens them in the page instead of the current composer (#2933).
