---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Native registration operations no longer reject with `busy` while another one
is running. They queue behind the native operation gate, so a Registration
created after a JavaScript reload waits for the previous runtime's pending
operation instead of failing. Registration rejections carry only their code.
`busy` is removed from the registration rejection codes and the native
diagnostics allowlist.
