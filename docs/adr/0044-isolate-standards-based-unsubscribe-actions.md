---
status: accepted
---

# Isolate standards-based unsubscribe actions

Unsubscribe detection will happen on device and scope an action to the Mailing List Identity conveyed by the currently expanded or newest eligible message, rather than a display sender or an entire mixed-sender Thread. The client will prefer RFC one-click HTTPS unsubscribe, then `mailto:`; an ordinary link remains an explicit Open Unsubscribe Page action. Every action requires user confirmation.

HTTPS unsubscribe uses an isolated, cookie-free, credential-free request boundary. It rejects authenticated URLs and private or local destinations, permits at most three HTTPS redirects with the same checks repeated at every hop, sends no referrer, and applies a 30-second aggregate deadline. The request sends only the standards-defined one-click body.

A successful response is described only as "Unsubscribe request sent"; the suggestion may return if that Mailing List Identity sends another eligible message after 14 days. The client never retries automatically after dispatch because a lost response is not proof that the request failed; it reports an uncertain outcome and allows an explicit retry. A `mailto:` unsubscribe is an ordinary outgoing message from the receiving Mailbox Connection, appears in Sent, and honors the Undo Send Window.
