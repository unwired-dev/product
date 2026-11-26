---
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

The assistance qualification build now runs a separate on-device clarification check before Rewrite, Expand Text, Shorten Text, Make More Friendly and Make More Neutral, and its corpus (version 5) adds cases that must and must not ask for clarification. Every other build edits exactly as before until the check qualifies (#2849).
