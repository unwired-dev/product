---
'@private-email/convex': patch
---

Fix Trusted Device revocation, which always failed against a real Convex deployment. Recent authentication now comes from the bearer token's `iat` on `POST /trusted-devices/revoke`, and the ownership-changing mutation is internal. The former public `productAccount:revokeTrustedDevice` mutation is retired. Key rotation accepts the replacement's schema 3 recovery envelope and keeps rejecting prototype schemas 1 and 2. Every bearer-authenticated HTTP route, including sign-in links and recovery material, now answers `401` instead of failing when the token is missing or invalid.
