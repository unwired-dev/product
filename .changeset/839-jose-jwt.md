---
'@private-email/convex': patch
---

Sign the APNs provider token and the Apple client secret, and verify Apple and Google
identity tokens, with `jose` instead of hand-written JWT code. An Apple identity token
that has expired or names another issuer now ends account deletion with "Apple
authorization exchange failed" instead of "Recent authentication must match the
Product Account"; a token for another identity or client keeps the latter message.
