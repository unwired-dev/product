# @private-email/convex

## 0.1.0

### Minor Changes

- 506964e: Send a Draft from the composer on iPhone, iPad and Mac. A sent Draft waits in the
  Outbox for a 10-second Undo Send Window, is claimed through Convex under an opaque
  identifier so only one Trusted Device can submit it, and is handed to Gmail
  as a formatted message with its files, inline images and reply threading. The
  Outbox shows messages waiting to send, refused ones to edit, and handed-off ones
  whose outcome is unknown, which are never sent again automatically.

  A mailbox refresh that prevents handoff keeps the message waiting to retry with
  its held claim, as does a retryable Gmail refusal such as a rate limit.

  If a mailbox changes its address, the composer keeps the Draft's chosen From
  address visible and asks for the mailbox to be chosen again. Queued messages
  stop before Gmail handoff if their chosen sender is no longer available.

  The composer is read-only while Send is pending and becomes editable again if
  admission is refused. Send dismisses any open translation or writing-help preview
  and prevents new requests while admission is pending.

- 8d15586: Every device after a Product Account's first now signs in as a Pending Device and joins only when an existing Trusted Device approves its Enrollment Code or the Recovery Key unlocks it. Signing in alone gives a new device no account data, Product Sync, push routing or Gmail authorization. The iPhone, iPad and Mac apps show an enrollment gate instead of "This device cannot join". The gate shows the code with **Check for approval**, offers **Use your Recovery Key**, explains why approval is needed, and allows signing out or deleting the account. A device becomes trusted only after it stores the authorized keys and confirms them.

  After a device removal, new devices can join again. The removed device's own identifier stays refused, and under a new identifier it waits like any other device. While the removal's key rotation is pending, only the replacement Recovery Key admits a new device. Convex now publishes a Recovery Key verifier with each recovery envelope, and the unseen-identifier lock and its identifier migration are removed. Pending Devices are limited to one per installation and three per account, and each ends with its Enrollment Code.

  Convex also removes the Product Sync reads that needed only a Product Sign-In; all Product Sync reads now require a Trusted Device proof. The legacy Swift client can no longer add a second device.

- 84a6f8d: Add Sign in with Apple as a Product Sign-In choice on iPhone, iPad and Mac, continuing into the separate, resumable Gmail authorization. Keep Apple relay addresses as contact information only, never link identities by email, and accept the replacement hosts' bundle IDs as Apple audiences in Convex.
- 59aec8b: Bind Product Account, Product Sync, and push-relay requests to device-only Trusted Device credentials.
- 754cb3d: Delete Product Accounts immediately after Apple authorization revocation and purge account-owned backend and reachable-device data.
- 4838390: Add encrypted Product Sync payload contracts and backend storage primitives for Recovery Key-based E2EE sync.
- dfab40f: Add Google Product Sign-In and separate, resumable device-local Gmail authorization in both native hosts. Validate Gmail grants before connection, retain accounts after interrupted consent, and keep Google refresh credentials off the backend.
- 7c38123: Link Google and Apple as verified alternate sign-ins for one Product Account. Linking reverifies the current sign-in, issues a short-lived single-use ticket bound to the Trusted Device, and completes only after the other identity signs in recently. It never merges accounts, matches by email or turns a Gmail mailbox into a sign-in. Either provider then opens the same account, and `productAccount:connect` reports its Sign-In Providers and rejects reconnects that would reach another account.
- cd85233: Add Account & Devices management with Trusted Device naming and opaque Recovery Key replacement.
- 4767b92: Allow one trusted device to connect, operate, and independently remove multiple Gmail mailbox identities.
- 7048de3: Initialize End-to-End Encrypted Product Sync for a new Product Account. The first Trusted Device creates device-held keys, publishes a Recovery Key envelope through the new `productSync:initialize` mutation, and presents the Recovery Key until its final group is confirmed. Initialization succeeds only for an account with no key material, so a device without local keys for an existing account enters enrollment instead of replacing them. The authorized Gmail mailbox descriptor round-trips as an encrypted record bound to its account, identifier, key epoch and schema.
- cb7297b: Add Apple-first Product Account sign-in with trusted device registration and shared connect response contracts.
- 34651eb: Remove another Trusted Device from the iPhone, iPad and Mac apps. Removal asks for a fresh sign-in and rotates the Product Sync keys, and it replaces the Recovery Key. Remaining devices adopt the new keys. A removed device deletes its account data and credentials when it next connects, including after an Apple relaunch. Saved-account operations check removal before opening sign-in, linking or Recovery Key prompts, so cancelling a prompt cannot retain a removed device's keys or credentials.

  Retrying a removal whose reply was lost shows its adopted replacement Recovery Key. A completion notice applies only to that earlier target; choosing another device preserves the key without claiming that device was removed. Confirm the key before starting another removal.

- 1bb24aa: Schedule Gmail delivery from the originating trusted device with an encrypted payload commitment, opaque background wake, ordinary Undo Send, and 24-hour Needs Attention deadline.
- 2d82cf4: Sign out of the current device, or permanently delete the Product Account, from the iPhone, iPad and Mac apps. Each action is confirmed first. Sign-out unregisters the device and its push routes, then removes the account's keys, credentials and session data from the device. Deletion asks for a fresh sign-in: with Apple whenever Sign in with Apple opens the account, so its authorization is revoked, and otherwise with Google. Convex adds a recently authenticated `POST /product-account/delete` route, so Google-only accounts can be deleted. Other devices purge a deleted account when they next reach Convex. Mail in Gmail is never deleted.

  Save and confirm an offered Recovery Key before signing out. Interrupted removals stay paused across relaunch and can be retried; acknowledged local cleanup finishes before provider authentication.

  A definite refusal of the first deletion attempt keeps the account usable. Refused retries of an unanswered deletion stay pending until confirmed. If this device learns that Apple also opens the account, its next deletion attempt uses Apple.

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
- 7fd6bca: Harden the Convex backend. Product Account deletion recovery now logs an allow-listed diagnostic before it aborts on a configuration failure or an unexpected defect. Exact encrypted Product Sync reads accept at most 100 identifiers. Identity token segments and Gmail push data are decoded with Effect Schema. The Gmail push HTTP action enqueues wakeups directly instead of calling another action in the same runtime. The unused `deliverGmailWakeups` path, which skipped recipient revalidation, is removed.
- da83d19: Align the workspace Convex SDK version with the generated Convex 1.41 guidance.
- 59aec8b: Authenticate every Product Account deletion retry with its Trusted Device proof.
- ab47b46: Add offline Mail Profile drafts, reviewed duplication, atomic connection transfer, and guarded
  Profile deletion.
- 4c6fd0b: Allow an eligible trusted device to claim a due Gmail Scheduled Send and durably fence provider handoff.
- 0f3566e: Enable Microsoft Graph actions, idempotent sending, authoritative delta reconciliation, and
  renewable race-safe mailbox-wide privacy-preserving push wake-ups.
- 33c3e07: Remove obsolete unconditional Product Sync payload mutations after all domains adopted the typed encrypted record boundary.
- 20d1137: Drop Convex indexes that duplicate the prefix of a wider index, pass explicit table names to document reads and writes, and read deployment environment through the generated `env` export.
- 18ae953: Add shared cross-boundary health contract and wire the Convex health action to its return validator.
- 4dc032e: Decode untrusted Convex input (HTTP bodies, identity tokens, provider key sets and responses, and APNs response headers) with Effect Schema, keeping the same responses and errors for malformed input.
- 3e7f1a7: Delete Apple-registered Product Accounts using the configured Apple client that issued the authorization, and stop accepting Apple tokens when neither APPLE_BUNDLE_ID nor APPLE_PRODUCT_CLIENT_IDS is configured.
- d4bc7ee: Fix Google and Apple sign-in linking rejecting fresh identities when Convex omits the reserved JWT issue-time claim. Validate freshness from the gateway-authenticated bearer token in HTTP actions, retain internal ownership transactions, and explain that the current provider is verified before the provider being linked. Rebuild the native hosts with the matching backend deployment.

  Load local host configuration for Mac native builds, use the active Ruby gem executables, and generate automatically signed Apple Development projects. Preserve Google SDK diagnostics in the private native log.

- 627c292: Polish Thread reader alignment, Message Category controls and User Override failure visibility, Catalyst subject presentation, and move Recovery Key material replacement behind a recently authenticated HTTP endpoint.
- 88bbcdc: Ignore unverified Gmail routes when deciding whether to stop a mailbox watch.
- 3507b10: Update the backend dependency toolchain and defer Gmail push proof cleanup into bounded Convex mutations.
- 80be581: Add per-device Gmail provider connection status metadata while keeping provider OAuth tokens device-held.
- e63b709: Require a verified Google mailbox identity before activating Gmail push routing.
- 88bbcdc: Add trusted-device APNs registration and a Gmail Minimal Push Metadata relay without storing provider credentials or mail content.
- b157c20: Manage Gmail Scheduled Sends from any compatible trusted device before provider handoff.
- 2e2a5ca: Import legacy signed-out Trusted Device identifiers before enforcing the account-wide revocation lock.
- 1e76216: Keep signed-out Trusted Devices owner-revocable across unregister races.
- a8dd542: Paginate encrypted Product Sync payload listing, keep legacy no-args listing calls compatible during rollout, track explicit Product Sync material initialization for connected Product Accounts, and cap sync listing pages server-side.
- 9612f48: Moves the Convex backend, the shared mail core and the iPhone, iPad and Mac apps from the Effect 4.0.0-rc.118 release candidate to the stable Effect 4.0.0 release. No user-visible behavior changes.
- 35850fa: Reject Product Sync record writes and the initialized marker until the account's recovery envelope exists. The legacy recovery-material route commits the initialized marker with a first envelope and answers `409` instead of creating key material for an account whose marker or records predate a missing envelope.
- 88bbcdc: Keep Gmail wakeup delivery and mailbox watches active for valid device routes.
- bd33345: Retire singular Gmail state, scope every mailbox path by connection, and route Gmail push through backend-only opaque HMAC digests.
- 5b6f0a1: Fix Trusted Device revocation, which always failed against a real Convex deployment. Recent authentication now comes from the bearer token's `iat` on `POST /trusted-devices/revoke`, and the ownership-changing mutation is internal. The former public `productAccount:revokeTrustedDevice` mutation is retired. Key rotation accepts the replacement's schema 3 recovery envelope and keeps rejecting prototype schemas 1 and 2. Every bearer-authenticated HTTP route, including sign-in links and recovery material, now answers `401` instead of failing when the token is missing or invalid.
- b628271: Revoke Trusted Devices with immediate API and push fencing, fail-closed provider setup,
  structured reconnect purge signaling, foreground token refresh, and concurrency-safe acknowledged
  Product Sync key rotation.
- cd164eb: Run the Apple, Google and APNs actions as Effect programs with tagged retryable and terminal failures, keeping the same responses, errors and retry persistence. APNs failure logs now carry only the status and a documented rejection reason. A Gmail identity token with a malformed signature segment now fails with the ownership proof rejection instead of a raw decoding error.
- 7a12e05: Add optimistic writes and paginated prefix reads for conflict-safe, bounded learning-signal payloads.
- db5ed32: Reconcile stale device push routes after failed authenticated unregistration without retaining obsolete identity tokens.
- 75873d1: Supersede active Product Sync key rotations with a fresh epoch before revoking another Trusted Device.
- 2d09eb1: Declare optional deployment environment settings for Convex code generation. The
  generated `env` export now exposes readonly, declared keys instead of an arbitrary
  string-keyed record, while preserving existing missing-configuration handling.
- a93506a: Use deployable Convex index identifiers for Gmail connection routing.
- Updated dependencies [1ccb9af]
- Updated dependencies [0548a1a]
- Updated dependencies [8d15586]
- Updated dependencies [da83d19]
- Updated dependencies [59aec8b]
- Updated dependencies [18ae953]
- Updated dependencies [754cb3d]
- Updated dependencies [4838390]
- Updated dependencies [80be581]
- Updated dependencies [88bbcdc]
- Updated dependencies [7c38123]
- Updated dependencies [cd85233]
- Updated dependencies [7048de3]
- Updated dependencies [cb7297b]
- Updated dependencies [a8dd542]
- Updated dependencies [6f28fe0]
  - @private-email/contracts@0.1.0
