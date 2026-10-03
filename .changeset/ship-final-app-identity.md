---
'@private-email/mobile': minor
'@private-email/macos': minor
---

Ship both hosts as "Unwired Mail" under the `dev.unwired.mail` bundle identifier with
the new app icon. The Mac host runs in the App Sandbox when signed, both hosts declare
exempt-only encryption, and each takes its version from its `package.json`.
