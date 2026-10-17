---
'@private-email/macos': patch
'@private-email/mobile': patch
'@private-email/localization': patch
---

Drafts and Mail Assistance follow the Mail Profile that owns their connection. A Draft's
Rewrite, Suggest reply and Translate use that Profile's consent, and a request is retired
when the connection moves to a Profile without it. Settings offers one Mail Assistance
switch per Profile; with only the Default Profile it is unchanged. Each window lists only
its own Profile's Drafts and Outbox. Moving a connection keeps its Drafts, the queued
message and its delivery claim.
