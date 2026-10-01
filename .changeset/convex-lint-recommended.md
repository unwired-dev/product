---
'@private-email/convex': patch
---

Drop Convex indexes that duplicate the prefix of a wider index, pass explicit table names to document reads and writes, and read deployment environment through the generated `env` export.
