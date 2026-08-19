---
'unwired-mail': patch
---

Detect List-Unsubscribe and List-Unsubscribe-Post headers for Gmail, Microsoft Graph, Exchange Web Services, and Standards-Based Mailbox Connections without requesting body bytes. Route mailto: unsubscribe requests through the receiving authorized sending-capable Mailbox Connection's durable SMTP Outbox. Preserve duplicate same-name headers in wire order using SwiftMail 1.11.0 additionalHeaderFields.
