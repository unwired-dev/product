Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to the replacement's native code: `native/private-inbox` (Swift package and React Native bridge) and the AppKit host in `apps/macos/macos`.

This code owns what TypeScript must never hold: Keychain items, the storage encryption key, Product Sync account-key material, sign-in tokens and file protection. The bridge is the only path between it and JavaScript. The replacement targets iOS, iPadOS and macOS 27.

#### Keys, credentials and storage

- A Keychain item that drops or weakens `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on creation, `kSecAttrSynchronizable: false` or the Mac Data Protection Keychain selection, or a new item that bypasses `DeviceKeychain` without preserving its policy. These keep keys on the device and out of iCloud Keychain and backups.
- Native database keys, Product Sync account-key material or provider/device credentials returned across the bridge. The intended local presentation payloads are permitted: decrypted Inbox snapshots and registration display fields, including the user-held Recovery Key during setup (`RegistrationSnapshotSchema`). None may enter logs, crash annotations, unprotected persistence or plaintext temporary files; temporary storage writes hold ciphertext only.
- A new key generated when the expected one is missing on an initialized account. A missing key means trusted-device approval or the user-held Recovery Key; a replacement key makes existing ciphertext unreadable.
- Ciphertext written without atomic replacement and file synchronization before the call resolves, without complete file protection on iOS, or into a directory included in backup.
- A read-modify-write, including first-run seeding, performed outside the native file lock, or that rewrites more than the requested record from a stale in-memory copy.
- AES-GCM used with a reused or predictable nonce, or a failed authentication treated as empty data rather than an error. Product Sync records and envelopes must retain their purpose-specific account, record/request/device, schema and epoch binding in `ProductSyncSeal`; the separate synthetic Inbox fixture retains its `dev.unwired.private-inbox.v1` context and is not account-scoped Product Sync storage.
- Filesystem access on iOS before the protected-data availability check, or a locked device reported as a generic failure rather than `locked`.
- Cleanup of old keys, envelopes or credentials ordered before the replacement is durably adopted.
- A revocation purge such as `RegistrationStore.purge` that stops account-item cleanup at the first failure, clears in-memory authorization only after a throwing read, or deletes the registration/retry locator before every dependent item is removed. Attempt every known item, retain the first failure and remove the locator last; otherwise credentials remain live in memory or a partial purge loses its account scope and cannot resume.
- `AccountRemoval.signOut` or `deleteAccount` sending irreversible remote work without durable local intent, or `purge` deleting dependent items before recording acknowledgement. Relaunch must finish acknowledged cleanup before provider work and keep unanswered removal from reconnecting an unregistered device; a lost reply is not proof that nothing was removed. `deleteAccount` must clear newly recorded intent after a definite refusal, but cannot clear an earlier unanswered attempt or make the bridge claim nothing was removed; otherwise a refused retry can reopen locally retained private state after remote deletion. Sign-out must reconcile rotation and retain any unconfirmed Recovery Key instead of discarding its sole backup.

#### Bridge contract

- A positive revocation found by `RegistrationStore.prepareMailbox` converted to ordinary mailbox invalidation after successful purge. Trace both `UnwiredRegistration.openMailbox` and `commitMailbox` through the shared rejection mapper and `createGmailInbox` recovery: preserve `mailbox-revoked` and its account-page hand-off, while generation changes retain bounded invalidation recovery. Collapsing the two makes already-purged mail end in retry exhaustion and a generic failure instead of the removal explanation.
- `RegistrationStore.purge` or Gmail reselection synchronously removing the
  mailbox/body directory or waiting for its file lock on the main actor. Await
  detached `removeMailboxCache` work under the registration gate until deletion
  completes, preserving early generation/session invalidation, cleanup failure
  and retry ordering, and keyless locked-device removal. Otherwise a populated
  cache stalls the interface or later work enters half-finished cleanup.

- `RegistrationStore` body operations doing synchronous file/crypto work on the
  main actor, or moving it off-main without mailbox/generation revalidation and
  protected-data checks before dispatch and before publishing success or failure.
  An off-main availability fallback must retain those checks in every production
  adapter, including `UnwiredPrivateInbox`'s fixture queue; otherwise locked access
  touches storage or returns plaintext, and suspended work can expose stale mail.
  Preserve the registration gate across the awaited transaction and keep file-lock
  serialization; a worker must never synchronously wait on the main actor under that lock.
- A rejection code that TypeScript does not know. `packages/mail-core/src/diagnostics.ts` allow-lists the codes; a new code needs the matching store handling and allow-list entry in the same task.
- A rejection or diagnostic that carries a foreign error description, account identifier, email address, token or path. JavaScript logs can leave the device; reject with a fixed code and fixed text, as `UnwiredPrivateInbox.perform` does. Successful values may contain the documented local presentation data consumed by the shared store; they must not be logged.
- A resolved payload whose shape changed without the `Schema` that decodes it in `mail-core` changing with it.
- A promise that can resolve twice, never resolve, or resolve after its owner is gone; blocking native work on the main queue that demonstrably stalls the UI. Registration presentation is `@MainActor`; that annotation alone is not a defect.
- A security decision moved to JavaScript: token validation, nonce and expiry checks, identity matching, lock state. The native host decides; TypeScript decoding complements it.
- A method exported to JavaScript that performs a privileged action on arguments it does not validate.

#### Identity and registration

- A saved Trusted Device operation, including `RegistrationStore.restore`/`reconfirm` and `revoke`, skipping the available credential-only revocation check before provider renewal, an interactive prompt or other user-cancellable work. A failed refresh/grant check or cancelled prompt must not suppress credential-proven revocation and leave account credentials and keys on a removed device. Apple cannot silently renew Product Sign-In after relaunch; provider credential state alone proves no device trust. A positive backend rejection must purge account credentials and keys before later provider access, while transport unavailability retains the owning resumable/offline state.
- An identity token accepted without the expected issuer, audience, subject and expiry checks, or an interactive sign-in result accepted without its session nonce check. SDK token refresh follows its owning refresh boundary; it does not reuse an interactive nonce requirement. Claims trusted after only client-side parsing where the backend must verify are also a defect.
- State from one Product Account, sign-in provider, device or deployment reused after any of them changes; an enrollment or recovery step that proceeds on a stale epoch or a stale authentication.
- Recovery Key verification that sends the key, an envelope encryption key or any derived secret beyond ADR 0066's explicit purpose-specific admission proof off the device, or a rejected key that leaves the device without its current enrollment status.
- A recent-authentication requirement removed from an operation that needs it.
- A client treating success from an idempotent backend operation as proof that its own proposal applied. `RegistrationStore.revoke` must verify exact-transition adoption through `adoptRotation` before presenting its generated Recovery Key or claiming that key is current; an already-completed removal may return success without applying this request, and post-success synchronization can fail. Promoting unmatched material can strand recovery, while an unconditional completion notice asks the user to save a key the client never adopted.
- A retry that reconciles an unanswered write but throws on a precondition the adopted effects created, leaving the caller's snapshot stale. `RegistrationStore.revoke` must return its adopted, unconfirmed Recovery Key for presentation before refusing a new removal. Attribute a completion notice to the saved attempt's target as well as its exact transition; adopting device A's removal while the caller requests device B cannot claim B was removed. Preserve the adopted key and start no new removal until confirmation.

- `PrivateInboxStore.openMailbox` selecting encrypted cached mail by address alone.
  Bind the saved owner to the immutable provider subject as well; a recycled
  address or cache left behind after failed cleanup must expose no previous mail.
- `RegistrationStore` Gmail reads or cache commits bound only to an address or a
  resettable cache revision. Carry and validate the cache-open authorization
  generation on every operation; a same-address subject change or purge/reconnect
  must reject old work before provider access or ciphertext replacement.

- `PrivateInboxStore` body admission that discounts an opposite-tier file before
  admission succeeds. Reserve both ciphertexts and plan eviction before deletion;
  refused admission must preserve the old body and protected entries. Remove the
  opposite tier before publishing its replacement, or interruption can leave two
  valid files and reads can return the older body. A failed replacement may leave
  a refetchable cache miss. Cache-only reads must not update access times
  or delete corrupt bodies; otherwise presentation-only access mutates storage.
- `PrivateInboxStore.retainMessageBodies` losing ordered `protectedIds` between
  host adapters, the Swift/Objective-C bridge and storage, or pruning bodies that
  received cache-fitting protection. Keep revision/generation checks and select
  protection in working-set order (newest first, then ascending ID), as required
  by `docs/gmail-inbox.md` and `docs/private-inbox-storage.md`. Sum stored bytes in
  both tiers per body name, count duplicate candidates once, and skip a candidate
  that does not fit while considering later candidates. Only fitting candidates
  receive protection; prune eligible bodies to maintain the hard limit. Protecting
  every over-budget candidate or refusing this reconciliation as a conflict
  reverses the accepted "Protect what fits" decision; losing fitting protection
  deletes recent offline bodies.

#### Mock sessions stay out of production

- A mock/test host factory such as `mockRegistrationStore` omitting a callback or proof required by a production operation's guard. Keep the real guard in place and wire the synthetic backend's owning state through it; otherwise optimistic/cached journeys can pass while the provider mutation is never reached and pending intent never settles.
- `MockGoogleRegistrationProvider.gmail` collapsing repeated `metadataHeaders`
  selectors, comparing header names case-sensitively, or projecting declared
  MIME headers differently in preflight metadata and full responses. Preserve
  every requested existing admission header from one message declaration;
  otherwise mock journeys can miss attachment exclusions or depend on selector
  order. Verify attachment and inline disposition controls without silently
  changing the packaged scenario's Inbox corpus or pagination.
- Synthetic registration providers reachable without the `UNWIRED_REGISTRATION_MOCK` compilation guard, or a Mock Mail Session selected from runtime input rather than the fixed build-time `UNWIRED_MOCK_SCENARIO` list. Other mock journeys and the isolated native `SyntheticCredential` integration fixture have their own test-only boundaries; preserve those instead of requiring the registration flag for every fixture. `SyntheticCredential` keeps its own Keychain service and never shares the production one.
- A reset, seed or backdoor added to production code to make a journey testable.

#### AppKit host

- Window identity, menu routing or lifetime moved out of AppKit; more than one React factory or JavaScript runtime per process; a window root that survives its window; Quit that leaves work running or closing the last window that terminates the app.
- An entitlement, sandbox exception, `Info.plist` privacy key or `PrivacyInfo.xcprivacy` entry added or broadened without the feature that needs it.
- A deployment target lowered, or a newer API used without the availability the target requires.
- A native module added to the Mac host without updating the autolinking assertion in `apps/macos/scripts/verify-bundle.ts`.

#### Tests in the same change

Apply `docs/agents/testing.md`'s admission and proportionate-verification policy: existing meaningful coverage may suffice; document unavailable automation or protected/native evidence with its required follow-up. The cases below identify missing evidence for a named risk, not a requirement to add a test for every edit.

- Changed storage, key or registration behavior with no Swift test in `native/private-inbox/Tests` or the on-device suite in `native/private-inbox/integration`. Package tests do not prove real Keychain or file-protection behavior on a device; say which evidence exists and which is deferred.

#### Leave to tooling

swift-format and SwiftLint findings, compiler diagnostics and Xcode analyzer results. The merged Swift and Objective-C rules cover language-level ownership, concurrency and error handling; apply them to runtime-derived values, not to fixed fixtures.
