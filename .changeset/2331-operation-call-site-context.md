---
'@private-email/contracts': patch
'@private-email/convex': patch
'@private-email/mail-core': patch
---

Error reports for a failed operation whose error carries no JavaScript stack, such as a failed HTTP/envelope response or an asynchronous native rejection, now include the bundle coordinates where the operation was requested. They are taken only while error reporting is on and reach PostHog marked as synthetic operation call-site context, not as the throw site (#2331).
