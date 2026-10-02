---
'@private-email/convex': patch
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

Fix Google and Apple sign-in linking rejecting fresh identities when Convex omits the reserved JWT issue-time claim. Validate freshness from the gateway-authenticated bearer token in HTTP actions, retain internal ownership transactions, and explain that the current provider is verified before the provider being linked. Rebuild the native hosts with the matching backend deployment.

Load local host configuration for Mac native builds, use the active Ruby gem executables, and generate automatically signed Apple Development projects. Preserve Google SDK diagnostics in the private native log.
