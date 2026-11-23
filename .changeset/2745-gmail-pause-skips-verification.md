---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

While Gmail's usage limit pauses a Gmail Inbox until the time Gmail named, registration verification no longer asks Gmail about that connection: activation, Refresh, every Try Again and push wakes skip it, including while its storage is locked or unreadable, and it keeps the access this process verified, so changes made meanwhile are still saved. It verifies again at Gmail's time. `createRegistration` and `createRegistrationFlow` take the `paused` connections, which the host reads from the new `Mailboxes.paused` and Inbox store `paused`; native `forgetMailboxAccess` takes the connections whose access it keeps (#2745).
