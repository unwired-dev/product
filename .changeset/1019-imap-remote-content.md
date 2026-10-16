---
'@private-email/mail-core': minor
'@private-email/localization': patch
'@private-email/mobile': minor
'@private-email/macos': minor
---

Load Remote Message Content in IMAP mail on iPhone, iPad and Mac. The IMAP reader now
follows the device's remote content policy and the connection's own setting, which
Settings offers for IMAP mailboxes too, with the same **Load images** consent,
Authorized Remote Content Cache, tracking-pixel blocking and shared display budget as
Gmail mail. `createImapInbox` accepts its `connection` and exposes `loadRemoteImages`
and `forgetRemoteImages`; `NativeImapMailbox` includes the remote content cache calls,
and the controlled `testing/imap-mailbox` fixture serves remote images. The reader's
"not loaded yet" notice for IMAP mail is removed.
