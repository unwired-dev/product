---
status: accepted
---

# Isolate standards-based unsubscribe actions

The Apple client owns mailing-list header parsing, Unsubscribe detection, confirmation, one-click requests, and `mailto:` delivery. It scopes an action to the Mailing List Identity conveyed by the currently expanded or newest eligible message, rather than a display sender or an entire mixed-sender Thread. The client will prefer RFC one-click HTTPS unsubscribe, then `mailto:`; an ordinary link remains an explicit Open Unsubscribe Page action. Every action requires user confirmation. The TypeScript backend never receives an unsubscribe URL, request body, recipient, or provider request.

HTTPS unsubscribe uses an isolated, cookie-free, credential-free request boundary. It rejects authenticated URLs and any literal or resolved non-public destination, pins one validated public address while preserving TLS authentication for the original hostname, permits at most three HTTPS redirects with the same resolution and destination checks repeated at every hop, sends no referrer, and applies a 30-second aggregate deadline. The request sends only the standards-defined one-click body.

Open Unsubscribe Page is a distinct, confirmed normal external-link navigation. The Apple client accepts only an HTTPS initial URL without embedded credentials, then hands that URL to the system browser. The browser, not the app, owns cookies, stored credentials, referrer policy, redirects, and every destination after the initial handoff; the app does not inject credentials or headers and does not claim the isolated one-click guarantees for this path.

A successful response is described only as "Unsubscribe request sent"; the suggestion may return if that Mailing List Identity sends another eligible message after 14 days. The client never retries automatically after dispatch because a lost response is not proof that the request failed; it reports an uncertain outcome and allows an explicit retry. A `mailto:` unsubscribe is an ordinary outgoing message from the receiving Mailbox Connection, appears in Sent, and honors the Undo Send Window.

Gmail and Exchange Web Services metadata synchronization request only `List-ID`, `List-Unsubscribe`, and `List-Unsubscribe-Post` alongside existing envelope metadata; they do not fetch a missing message body to discover an action. EWS reads those values as named `InternetHeaders` extended properties, keeps them associated with the owning item and stable search-key identity in device-local durable metadata, and routes `mailto:` through that receiving EWS Mailbox Connection and the shared Outbox. Header values, unsubscribe destinations, and request data remain device-local and never enter Product Sync.
