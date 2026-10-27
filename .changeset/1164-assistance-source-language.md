---
'@private-email/mobile': patch
'@private-email/macos': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

On-device summaries and rewrites ask for the language of the message or authored text (#1164). When it confidently identifies that language, the native binding names it to Apple's model and rejects an unsupported language or a confidently detected output language switch as `unsupported-language`. The preview explains the limitation and mail and Drafts stay unchanged. Rewrite instructions forbid added subject lines, greetings and signatures. The assistance qualification corpus is now version 4, with heuristic checks for language switches and added letter framing. Generated text still needs human review.
