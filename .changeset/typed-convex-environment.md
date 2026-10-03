---
'@private-email/convex': patch
---

Declare optional deployment environment settings for Convex code generation. The
generated `env` export now exposes readonly, declared keys instead of an arbitrary
string-keyed record, while preserving existing missing-configuration handling.
