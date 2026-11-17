---
'@private-email/mail-core': patch
---

Keep a Draft's composer recovery record while a conflicting copy its editor
moved to is stored neither as a Draft nor as its own record, so another composer
closing the original cannot remove the only copy of those edits.
