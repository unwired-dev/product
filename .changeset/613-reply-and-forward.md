---
'@private-email/localization': minor
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Reply, Reply All and Forward from the Gmail reader on iPhone, iPad and Mac (#613).

- **Sender:** a response starts a Draft from the mailbox that received the message, and only while that mailbox can send. Choosing another sender keeps the reply's threading headers but not the receiving mailbox's Gmail thread.
- **Recipients:** Reply goes to Reply-To or From, or to the original recipients of a message the mailbox sent. Reply All adds the other To and Cc recipients once each, without the sending address. Groups keep their members, and invalid entries are left out.
- **Threading:** replies keep `Re:` subjects, the Gmail thread, In-Reply-To and up to 20 References. Forwards keep `Fwd:` subjects. Opened bodies now keep their addressing and threading headers.
- **Quoted text:** the answered message's readable text stays apart from the authored body, read-only behind Show quoted text.
- **Forwarded files:** Forward downloads every attachment and copies it, with resolved inline images, into Draft Assets. Files that cannot be copied stay unsendable.
