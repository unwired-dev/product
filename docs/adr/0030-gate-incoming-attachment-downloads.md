---
status: accepted
---

# Gate incoming attachment downloads in message presentation

Incoming attachments use a provider-neutral descriptor and download operation. A message presentation may start that operation only through the device-local attachment policy: On Demand requires an explicit user action, Wi-Fi starts automatically on Wi-Fi or wired networking, and Always starts automatically on any available network. Policy or network changes and presentation dismissal cancel the presentation-scoped task. Failures keep the message readable and offer a retry.

Gmail is the first provider implementation because its explicit body read already returns the full MIME tree and its authenticated attachment endpoint is independently callable. Ordinary attachment-disposition parts and filename-bearing non-inline parts are exposed; inline Content-ID images remain part of the isolated message presentation instead. Gmail may include small attachment bytes in that required MIME response before a per-attachment decision is possible; the full response is capped at 40 MB, those bytes stay presentation-scoped, and the encrypted body cache stores only their descriptors. Legacy cache entries that lack attachment metadata are refreshed. Other providers expose no descriptors until their adapters implement the same boundary, so they have no attachment request path that can bypass the gate.

Downloads are limited to 25 MB, validated against provider-declared size when present, and bounded while reading the authenticated endpoint response rather than after an unbounded buffer. Successful downloads are saved under opaque connection, message, and part digests in Application Support with complete file protection. The store is capped at 250 MB with oldest-file eviction and is cleared with the owning Mailbox Connection or Product Account. The original filename is reduced to its final path component. Downloaded bytes remain device-local and never enter the encrypted message-body cache or Product Sync.

The reader derives preview availability only for passive image, PDF, plain-text, audio, and video types. Image and PDF thumbnails are generated in memory from the protected local file, and tapping either a thumbnail or the Quick Look action presents that same file through the system preview. Preview access refreshes the stored file's modification date so the existing 250 MB eviction policy treats recently previewed content as recently used. The app creates no separate plaintext or synchronized preview cache; unsupported types retain the explicit Share / Open path.
