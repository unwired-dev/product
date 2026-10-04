---
'@private-email/convex': patch
---

Reject Product Sync record writes and the initialized marker until the account's recovery envelope exists. The legacy recovery-material route commits the initialized marker with a first envelope and answers `409` instead of creating key material for an account whose marker or records predate a missing envelope.
