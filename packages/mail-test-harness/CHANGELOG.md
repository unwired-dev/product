# @private-email/mail-test-harness

## 0.1.0

### Minor Changes

- 00dd76d: Add a secure, ownership-scoped GreenMail IMAPS and SMTPS smoke harness.
- 4fe8757: Exercise incremental mail arrival and thread reconciliation through the production refresh path.
- 6425f5a: Exercise production System Categorization with synthetic mail and redacted visible-assignment evidence.
- 7b1a50f: Exercise visible compose and reply flows with capability-aware Outbox, SMTP, recipient, Sent,
  duplicate-delivery, and threading evidence.
- 48bb3df: Open each Core Mail Loop run in an owned Mail Test Device and verify the Synthetic Test Message through the production IMAP interface.
- e387537: Add an ownership-checked persistent Manual Mail Sandbox with start, status, inject, reset, and stop commands.
- aa17dc5: Enable two-mode Scheduled Send after protected provider compatibility evidence and add deterministic local release coverage.
- 9ee6bc6: Exercise visible read and organization steps with stable accessibility identifiers, independent IMAP state assertions, and explicit reporting for unavailable provider capabilities.

### Patch Changes

- 7b1a50f: Close abort-listener registration races in IMAP and TLS sessions.
- 9732603: Keep a Mail Test Run's ownership record when Simulator cleanup fails, so `doctor` reports the orphan and a later cleanup can still prove ownership.
- 25717c8: Preserve coalesced protocol responses and split UTF-8 input in the mail test harness while bounding buffered response frames.
- 5f9daa0: Report the visible scenario step, semantic UI state, and independent server assertion state in redacted Core Mail Loop failure evidence.
- b9f332b: Add an on-demand synthetic MIME presentation scenario with visible-client assertions, remote-content blocking evidence, and server-state invariants.
