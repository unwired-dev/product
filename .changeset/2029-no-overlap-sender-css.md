---
'@private-email/mail-core': patch
---

Stop sender styles from pulling reader text under an inline image or onto a button fill: negative
margins and text indents become zero, and text wraps inside its box instead of overflowing it
(#2029).
