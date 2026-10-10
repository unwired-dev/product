# @private-email/contracts

## 0.1.0

### Minor Changes

- 0548a1a: Remove the unused response fixtures for Product Account connect, Gmail provider connection, encrypted Product Sync payloads and push relay registration. The Convex tests validate these responses against the same contract validators.
- 8d15586: Every device after a Product Account's first now signs in as a Pending Device and joins only when an existing Trusted Device approves its Enrollment Code or the Recovery Key unlocks it. Signing in alone gives a new device no account data, Product Sync, push routing or Gmail authorization. The iPhone, iPad and Mac apps show an enrollment gate instead of "This device cannot join". The gate shows the code with **Check for approval**, offers **Use your Recovery Key**, explains why approval is needed, and allows signing out or deleting the account. A device becomes trusted only after it stores the authorized keys and confirms them.

  After a device removal, new devices can join again. The removed device's own identifier stays refused, and under a new identifier it waits like any other device. While the removal's key rotation is pending, only the replacement Recovery Key admits a new device. Convex now publishes a Recovery Key verifier with each recovery envelope, and the unseen-identifier lock and its identifier migration are removed. Pending Devices are limited to one per installation and three per account, and each ends with its Enrollment Code.

  Convex also removes the Product Sync reads that needed only a Product Sign-In; all Product Sync reads now require a Trusted Device proof. The legacy Swift client can no longer add a second device.

- 59aec8b: Bind Product Account, Product Sync, and push-relay requests to device-only Trusted Device credentials.
- 18ae953: Add shared cross-boundary health contract and wire the Convex health action to its return validator.
- 754cb3d: Delete Product Accounts immediately after Apple authorization revocation and purge account-owned backend and reachable-device data.
- 4838390: Add encrypted Product Sync payload contracts and backend storage primitives for Recovery Key-based E2EE sync.
- 7c38123: Link Google and Apple as verified alternate sign-ins for one Product Account. Linking reverifies the current sign-in, issues a short-lived single-use ticket bound to the Trusted Device, and completes only after the other identity signs in recently. It never merges accounts, matches by email or turns a Gmail mailbox into a sign-in. Either provider then opens the same account, and `productAccount:connect` reports its Sign-In Providers and rejects reconnects that would reach another account.
- cd85233: Add Account & Devices management with Trusted Device naming and opaque Recovery Key replacement.
- 7048de3: Initialize End-to-End Encrypted Product Sync for a new Product Account. The first Trusted Device creates device-held keys, publishes a Recovery Key envelope through the new `productSync:initialize` mutation, and presents the Recovery Key until its final group is confirmed. Initialization succeeds only for an account with no key material, so a device without local keys for an existing account enters enrollment instead of replacing them. The authorized Gmail mailbox descriptor round-trips as an encrypted record bound to its account, identifier, key epoch and schema.
- cb7297b: Add Apple-first Product Account sign-in with trusted device registration and shared connect response contracts.
- a8dd542: Paginate encrypted Product Sync payload listing, keep legacy no-args listing calls compatible during rollout, track explicit Product Sync material initialization for connected Product Accounts, and cap sync listing pages server-side.
- 6f28fe0: A new device of an existing Product Account asks a Trusted Device for approval and
  shows a one-time Enrollment Code. The trusted device seals the account's Product
  Sync keys to that device with HPKE, using the code as the pre-shared key. Convex
  stores only the request and the sealed approval through the new
  `productSyncEnrollment` functions. It refuses replayed, expired, declined,
  superseded, revoked and mismatched approvals without touching account keys. The
  approved device reads the synchronized mailbox list while Gmail still needs its own
  authorization.

### Patch Changes

- 1ccb9af: Keep Draft Discard and divergent edits safe across interrupted publication and updates,
  concurrent local stores and relaunch. Log failed automatic synchronization passes
  and distinguish deleted-record conflicts from transport failures.
  Automatic app lifecycle requests use the shared `syncInBackground` action;
  explicit `sync` callers continue to receive unexpected rejections.
  Mac windows share one Draft lifecycle subscription so each app transition starts
  one synchronization pass for their shared store.
- da83d19: Align the workspace Convex SDK version with the generated Convex 1.41 guidance.
- 80be581: Add per-device Gmail provider connection status metadata while keeping provider OAuth tokens device-held.
- 88bbcdc: Add trusted-device APNs registration and a Gmail Minimal Push Metadata relay without storing provider credentials or mail content.
