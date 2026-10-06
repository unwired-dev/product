---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Refuse Gmail messages nested more than 32 MIME levels deep or with more than
10,000 parts instead of exhausting the stack while reading them. Inspect a
link's painted text apart from admitted image descriptions, so an image's
alt text cannot mask a mismatched address. Render a message's replacement
presentation after an earlier rich view failed.
