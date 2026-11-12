---
'@private-email/mail-core': patch
---

Add `requestUnsubscribe`, which sends a one-click offer's RFC 8058 request once through the isolated native request path and reports it sent, failed or uncertain (#2077, part of #654).
