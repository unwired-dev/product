---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Preserve same-account late Draft edits as conflict copies after deletion, keep
edits accepted during a failed discard, and allow navigation to retry after an
unexpected composer save failure.

Leave unchanged editor content alone when another writer saves a newer Draft,
without creating a stale conflict copy. Expose the shared composer navigation
coordinator for both hosts.
