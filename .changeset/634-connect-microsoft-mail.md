---
'@private-email/mail-core': minor
'@private-email/localization': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Connect and read Microsoft mail on iPhone, iPad and Mac. Product Sign-In with Google or Apple no longer starts Gmail consent on its own: **Connect your mail** offers **Authorize Gmail**, **Choose another Google mailbox** and **Connect Microsoft mail**, and the account page adds **Add a Microsoft mailbox**. Microsoft actions appear only when the build has a configured Microsoft client ID or a mock provider. A personal Outlook.com or work/school Microsoft 365 mailbox connects through Microsoft's sign-in with read-only mail access, without any Gmail grant, and its Inbox joins the unified Inbox through Microsoft Graph: the newest 200 messages first, then delta changes, with bodies, inline images and attachments read on demand into the same encrypted caches. Cancelled or refused consent, tenant restrictions, an account without an Outlook mailbox, expired delta state and a refused grant each keep the Product Account and show a state to retry or authorize again. A grant refused while reading attachment metadata still asks for authorization when the message also exceeds the MIME metadata budget. Organizing, online search and sending stay Gmail-only for now.
