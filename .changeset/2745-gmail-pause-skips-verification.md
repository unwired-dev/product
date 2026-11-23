---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

While Gmail's usage limit pauses a Gmail Inbox until the time Gmail named, registration verification no longer asks Gmail about that connection: activation, Refresh, every Try Again and push wakes leave it opening from its cache until it verifies at Gmail's time, including while its storage is locked or unreadable. `createRegistration` and `createRegistrationFlow` take a `paused` connection check, which the host answers from the new `Mailboxes.paused` and Inbox store `paused` (#2745).
