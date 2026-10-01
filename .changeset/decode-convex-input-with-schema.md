---
'@private-email/convex': patch
---

Decode untrusted Convex input (HTTP bodies, identity tokens, provider key sets and responses, and APNs response headers) with Effect Schema, keeping the same responses and errors for malformed input.
