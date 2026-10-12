---
'@private-email/mail-core': minor
'@private-email/localization': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Connect IMAP mailboxes and read their folders and messages on iPhone, iPad and Mac.
**Connect your mail** and the account page's **Mailboxes** section now also offer
iCloud Mail, Fastmail and another IMAP server. An IMAP connection shows its reviewed
endpoint before connecting, uses implicit TLS with verified certificates, keeps its
password in this device's Keychain and stays receive only until SMTP is added. A
refused, unreachable or insecure server keeps the Product Account and resumes setup
after relaunch; a refused password is entered again on the account page.

iCloud Mail retries a refused name-part login once with the full address. Native
IMAP projections require a valid endpoint for password repair, and shown rows of
still-selectable evicted folders survive Inbox reloads while their connection remains open.

IMAP mail synchronizes by folder, UIDVALIDITY and UID into the encrypted cache,
resumes from its committed checkpoint, and joins the unified Inbox of its Mail
Profile; choosing an IMAP mailbox on its own shows its folders. Missing or zero
UIDVALIDITY refuses message reads and cache admission. The reader shows the
sanitized body and inline images; remote content stays blocked and attachments are
counted only. `MailProvider` gains `imap`, and `MailGrantProvider` names the
providers authorized through their own sign-in. `@private-email/mail-core` exports
`imap-inbox`, `imap-setup` and a controlled `testing/imap-mailbox` provider fixture.
Local search reports actual IMAP body-cache availability. Folder refresh failures
keep cached rows with a warning, and a removed folder choice falls back to Inbox.
Both hosts share the exported `imapFolderName` and `imapFolderFailed` projections.
Case variants of `INBOX` use one folder identity; other folder names stay distinct.
Successful folder synchronization prunes bodies of expunged or UIDVALIDITY-reset
messages while retaining saved bodies for rows still shown from an evicted folder.
Successfully saved folder listings also retire cached mail and views for removed
or non-selectable folders. Failed listing commits preserve shown rows; oversized
lists and unavailable namespace discovery retain prior cached mail for retry.
