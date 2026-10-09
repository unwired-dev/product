---
'@private-email/mail-core': patch
'@private-email/convex': patch
'@private-email/contracts': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Keep Draft Discard and divergent edits safe across interrupted publication and updates,
concurrent local stores and relaunch. Log failed automatic synchronization passes
and distinguish deleted-record conflicts from transport failures.
Automatic app lifecycle requests use the shared `syncInBackground` action;
explicit `sync` callers continue to receive unexpected rejections.
Mac windows share one Draft lifecycle subscription so each app transition starts
one synchronization pass for their shared store.
