---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Decode message bodies in legacy single-byte charsets, including Czech
`windows-1250` and `iso-8859-2`, on iPhone, iPad and Mac instead of showing
garbled UTF-8 text.
