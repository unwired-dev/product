---
'@private-email/macos': patch
---

On Mac, files dropped on the Draft editor page of `registration-draft-editor` builds are
attached, as on the current composer: native code reads them from the drag pasteboard, and the
page still never reads their data (#2950).
