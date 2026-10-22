---
'@private-email/convex': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Mail sent after relaunching the app with a Sign in with Apple account no longer
stays in the Outbox on "Waiting to send". The delivery claim is now proven by the
Trusted Device's own credential instead of a Product Sign-In, which Sign in with
Apple cannot renew without asking. Builds from before this change need updating
once the backend is deployed.
