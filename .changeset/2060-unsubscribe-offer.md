---
'@private-email/mail-core': patch
---

Keep an opened message's `List-Id`, `List-Unsubscribe` and `List-Unsubscribe-Post` headers for Gmail, Microsoft Graph and IMAP, and add `unsubscribeOf`, which finds its RFC 8058 one-click or `mailto:` unsubscribe offer (#2060, part of #654).
