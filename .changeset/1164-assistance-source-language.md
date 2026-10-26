---
'@private-email/mobile': patch
'@private-email/macos': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

On-device summaries and rewrites keep the language of the message or authored text (#1164). The native binding names that language to Apple's model, and rejects a language the model cannot write, or a result in another language, as `unsupported-language`: the preview says the language is not supported and mail and Drafts stay unchanged. Rewrites no longer add a subject line, greeting or signature. The assistance qualification corpus is now version 4, with cases that fail a switched language or added content.
