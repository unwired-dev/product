Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to the replacement's native code: `native/private-inbox` (Swift package and React Native bridge), `native/localization` and the AppKit host in `apps/macos/macos`.

Native storage owns what TypeScript must never hold: Keychain items, the storage encryption key, Product Sync account-key material, sign-in tokens and file protection. The bridge is the only path between it and JavaScript. The replacement targets iOS, iPadOS and macOS 27.

#### Bundled localization resources

- `UnwiredLanguagePreferences.catalog` relying on a Debug assertion before using
  missing or invalid catalog data. Handle failed reads and JSON parsing before
  Foundation calls that reject nil; cache failure without inserting nil into a
  collection, and preserve `UnwiredNativeText`'s English fallback. Otherwise a
  missing translation resource crashes Release instead of falling back. Verify
  the failure path with assertions disabled, including repeated cached lookups.

#### Keys, credentials and storage

- `PrivateInboxStore.commitDraftDocument` allowing garbage collection after durable
  document replacement to reject that stored revision. Keep post-write removal
  best effort and retry leftover ciphertext on a later save, without removing
  referenced or still-importing assets. Otherwise the host reports Not saved for
  a committed document and can repeatedly rebase a save that already succeeded.

- `PrivateInboxStore.commitDraftDocument` admitting a replacement document against
  only retained Draft Assets while unkept files still occupy the Outgoing Content
  Store. Count every on-disk asset, including failed-removal leftovers, with the
  new encoded ciphertext before writing; discount a file only after it is removed.
  Preserve post-write best-effort cleanup and refusal without document mutation.
  Otherwise repeated saves can exceed the non-evicting hard limit after cleanup
  fails, even though each admission appears to fit its retained references.

- `PrivateInboxStore.commitDraftDocument` or another bounded encrypted write
  admitting only the raw input size. Count the encoded envelope, including JSON
  string escaping, and the nonce/tag overhead of the exact stored format before
  key creation, deletion or replacement. Refusal must preserve existing content;
  otherwise an input below the nominal limit can exceed the stored-byte budget.

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

- `DraftFilePicker` treating a protected staging directory as sufficient for a
  moved document-picker copy or a copied Photos/pasteboard representation. Set
  complete file protection on each staged plaintext file itself before returning
  its URI; existing files can retain their source protection class after a move
  or copy. A protection-setting failure must reject intake and remove the owned
  target through the same failure cleanup as a failed copy or move. Trace every
  app-owned staging write and preserve user originals and system-owned provider
  lifetimes. Otherwise staged Draft bytes can remain readable while the device
  is locked until import or launch cleanup; a Simulator build alone does not
  qualify locked-device enforcement.

- `RegistrationStore.importDraftAsset` accepting an arbitrary JavaScript file path
  as an alternative to the generation-checked received-attachment source. Admit
  only actual picker-owned copies or sandbox-granted external Mac files; reject
  app-container paths and external symlink aliases to them. Trace
  `isPickedDraftFile`/`allowsDraftFile`, picker creation and cleanup, and
  `attachmentFile` together. Otherwise a caller can name a Downloaded Attachment's
  plaintext path and skip its Mailbox Connection generation check. Picker cleanup
  must still remove only its owned copies, never similarly named user folders.

- `DraftFilePicker` leaving photo selection unlimited or copying/encoding every
  document or pasteboard image before applying the documented per-intake count
  limit. Bound work at the earliest platform boundary: applying `prefix` after
  an eager platform API such as `UIPasteboard.images` has materialized or decoded
  the whole collection does not bound that work. Filter provider metadata and
  cap the lazy sequence before loading image representations. Where the system
  already copied document selections, remove unused system copies and move only the
  admitted prefix into picker-owned storage. Preserve cancellation/failure cleanup
  and never delete user-owned originals. Trace the shared `drafts.ts.pick` and Mac
  paste/drop consumers too; otherwise large selections create unbounded plaintext
  staging and composer work outside the encrypted store's byte-admission limit.

- `DocumentDelegate.documentPicker` in `DraftFilePicker.swift` cleaning up only
  files already moved into `draft-picks` when a selected batch fails. The picker
  uses `asCopy: true`; attempt
  removal of every system-created selection URL, including
  the failing and not-yet-processed copies, as well as already-moved targets.
  Verify destination-creation and move failures after an earlier successful move;
  preserve the original error and never apply this removal to open-in-place or
  user-owned URLs. Otherwise plaintext remains in the system picker inbox outside
  the root that launch cleanup removes.

- `DraftFilePicker.PhotoDelegate.copy` or document intake checking the per-file
  byte limit only after copying or moving a loaded representation into app-owned
  staging. Check the loaded file's logical size before that work; keep oversized
  items visible as URI-less too-large results and trace their decoding, inline
  preparation, import settlement and cleanup in `drafts.ts`. Preserve the native
  import's final byte-admission check and never remove a user-owned original.
  System-created temporary representations may precede inspection, so do not
  claim the limit prevents that platform work. Otherwise a bounded selection of
  oversized assets still consumes substantial plaintext staging space and time
  before encrypted storage refuses it.

- `pickedFile` in `DraftFilePicker.swift` or `PhotoDelegate.copy` inferring an imported
  image's MIME type only from its display name or renamed staging path, despite
  the source's declared type or original URL extension. Prefer a concrete
  declared MIME type; generic types such as `public.image` have none, so preserve
  the original URL's extension fallback independently of naming. Preserve an
  unnamed source's complete filename, including dots in its stem, and avoid
  duplicating extensions already present in suggested names. Check extensionless
  concrete image providers and generic providers with dotted names. Apply this
  check to every shared `pickedFile` caller, including Mac open-panel selections,
  iOS staged document copies and URI-less oversized entries. Filesystem
  `contentTypeKey` metadata can return `public.data` for valid extensionless image
  bytes; require real-file evidence rather than assuming metadata inspects the
  content. Preserve concrete declared types, bounded header work, grants and
  staging/size/cleanup boundaries when identifying an otherwise unknown image;
  otherwise
  `prepareFiles` can silently turn Insert Image or Paste Image into an attachment
  or retain incorrect asset metadata.

- `UnwiredAssistance.summarize` and `cancel` losing the serial bridge's invocation
  order while dispatching to their shared request registry. Preserve registration
  before a later cancellation and check cancellation before generation starts;
  independent unstructured actor tasks can let cancellation find no request and
  then start explicitly cancelled inference. Cancellation during availability or
  after completion must not accumulate request IDs that will never be consumed.

- `GmailTransport.send` consuming an allowed large response through one async
  iterator step per byte while the shared `RegistrationOperationGate` is held.
  Receive bounded chunks, reject declared and streamed overflow before retaining
  it, preserve redirect refusal and cancel the owning transfer. Keep a terminal
  result when a suspended task completes cancellation before its continuation is
  registered, and settle once for either ordering; otherwise a near-limit attachment
  stalls all mailbox/registration work or cancellation strands the gate indefinitely.
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

- `PrivateInboxStore` body admission that discounts another tier's file before
  admission succeeds. Reserve existing tier ciphertexts and the replacement, and
  plan eviction before deletion;
  refused admission must preserve the old body and protected entries. Remove every
  other tier before publishing its replacement, or interruption can leave two
  valid files and reads can return the older body. A failed replacement may leave
  a refetchable cache miss. Cache-only reads must not update access times
  or delete corrupt bodies; otherwise presentation-only access mutates storage.
- `PrivateInboxStore.retainMessageBodies` losing ordered `protectedIds` between
  host adapters, the Swift/Objective-C bridge and storage, or pruning bodies that
  received cache-fitting protection. Keep revision/generation checks and select
  protection in working-set order (newest first, then ascending ID), as required
  by `docs/gmail-inbox.md` and `docs/private-inbox-storage.md`. Sum stored bytes in
  every supported tier per body name, count duplicate candidates once, and skip a candidate
  that does not fit while considering later candidates. Only fitting candidates
  receive protection; prune eligible bodies to maintain the hard limit. Protecting
  every over-budget candidate or refusing this reconciliation as a conflict
  reverses the accepted "Protect what fits" decision; losing fitting protection
  deletes recent offline bodies.

#### Mailbox Connection lifecycle

- `synchronizeMailboxes` treating an epochless connection or queued removal as
  compatible with every live epoch. Pre-epoch connections, descriptors and
  removal intents name one fixed legacy incarnation; concurrent upgrades must
  agree without purging other legacy devices. Preserve tombstones and fence
  later re-adds, including retained offline recreation after another device's
  legacy upgrade. Otherwise migration restores old authorization or removes a
  later incarnation with stale intent.
- `PrivateInboxStore.adoptLegacyMailbox` assuming the connection's body folder
  is absent, or merging by a tier-suffixed filename rather than body identity.
  A body may be saved before metadata adoption; preserve that destination body
  across every supported tier and keep interrupted migration
  retryable. Otherwise cache open repeatedly fails or an older legacy body
  becomes the preferred readable copy.
- `synchronizeMailboxes` treating a missing entry in `descriptorEpochs` as an
  unchanged incarnation for offline consent, or discarding an authenticated
  removal/different epoch from an address-update CAS when its later list fails.
  Adopt an offline grant only against a known observed live epoch that still
  matches, and durably purge a known removal before another fallible read or
  another connection's publication. A batch that waits until all writes finish
  loses learned removals when a later connection fails.
  Absence cannot rule out an unseen add/remove/re-add; either gap retains stale
  provider authorization after a synchronized removal.
- `synchronizeMailboxes` discarding the descriptor returned by a losing CAS or
  adopting any different epoch from a later list merely because it attempted a
  write. Bind eligible fresh consent or matching retained recreation to the
  live CAS winner, persist that epoch before later fallible reads, and require
  final read-back to match it. Tombstones, ordinary offline restore, published
  address updates and subsequent removals cannot extend an old grant to another
  incarnation; otherwise concurrent additions lose valid mail or resurrect
  authorization after removal.
- `PrivateInboxStore.bodies()` omitting unadopted root `bodies/` from device-wide
  admission and eviction totals. Count every supported layout until adoption or
  removal; moving legacy bodies under `mailboxes/<id>` must count them once.
  Keep `bodies(connection)` and list/membership pruning connection-scoped, and
  preserve legacy metadata during body eviction. Otherwise legacy mail adds a
  second cache quota or pruning destroys another connection's pending actions.
- `synchronizeMailboxes` acknowledging a queued removal from absent or unreadable
  ciphertext, or discarding removal intent on a pre-publication re-add. Require a
  read-back tombstone or an authoritative superseding incarnation, preserve
  read-only unknown records, and fence pre-removal authorization with a new epoch.
  Ordinary restore of unpublished credentials cannot resurrect a tombstone or
  adopt another incarnation; only current explicit consent or a retained matching
  recreation intent may do so. Otherwise an offline device restores a removed
  connection's provider access.
- `removeMailbox` or synchronized descriptor purge deleting caches before durable
  credential removal and retry recording, returning a stale connection list after
  later failure, or omitting an unopened legacy root cache. Trace cleanup through
  `SavedRegistration` and `retryMailboxCleanup`: preserve owner-specific keyless
  legacy cleanup, attempt every owned path, and keep failed cleanup retryable without
  reopening the connection. Otherwise partial cleanup retains credentials/plaintext
  or loses another connection's durable pending actions.

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

#### Attachment presentation

- `UnwiredRegistration.presentAttachment` resolving the presentation window after
  gate/storage suspension, or `AttachmentPresenter` capturing a window without
  routing Quick Look's shared panel through that window's responder chain. Capture
  the native origin before those waits, anchor sharing to its view, and verify
  Quick Look acquired its controller before acknowledging presentation. Refuse a
  closed/hidden origin or an inactive UIKit scene without selecting another window;
  otherwise focus changes disclose one reader's file in another window, show the
  wrong preview, or strand a presentation lease after false success.
- `AttachmentPresenter` or `UnwiredRegistration` ending file ownership at reader
  unmount while Quick Look or a share service still consumes its URL. Keep each
  presentation's data source/delegate strongly owned until its own completion,
  release its lease once, and recheck leases inside the operation gate before a
  deferred discard. `PrivateInboxStore.saveAttachment` must skip leased files
  without exceeding its hard quota; refuse admission before deletion when they
  leave insufficient space. Check replacement, stacked previews, panel/window
  close, picker cancellation and service success/failure; otherwise delayed
  preview or sharing fails, or leaked leases retain plaintext until relaunch.

#### AppKit host

- `AttachmentPresenter` installing a controller only through `NSResponder.nextResponder`
  or a Quick Look data source, both unretained references. Give each window's
  controller an explicit strong owner through its active lifetime; on close,
  restore owned responder links, detach its panel data source and release its
  observer and owner. Check identities before teardown so another window's preview
  remains intact; otherwise AppKit messages a dangling controller or a closed
  window retains presentation state indefinitely.
- Window identity, menu routing or lifetime moved out of AppKit; more than one React factory or JavaScript runtime per process; a window root that survives its window; Quit that leaves work running or closing the last window that terminates the app.
- A composer change reviewed without inventorying native exits in
  `apps/macos/macos/UnwiredMail/AppDelegate.mm`: window close/Command-W and
  application termination/Quit can bypass `useLeaveComposer` before destroying
  an editor or its runtime. Trace unfinished recipients and pending, failed or
  locked saves through those paths, including closing the last window and Quit
  with no windows. Require qualified protection or an explicitly accepted,
  tracked pre-release gap with visible recovery and truthful durability limits;
  retaining edits in the process-wide store after window close does not preserve
  them after Quit. Preserve forced account/device invalidation and AppKit's
  close-versus-Quit lifetime contract. JavaScript bundle checks do not compile
  this Objective-C++ host or exercise its lifecycle delegates.
- An entitlement, sandbox exception, `Info.plist` privacy key or `PrivacyInfo.xcprivacy` entry added or broadened without the feature that needs it.
- A deployment target lowered, or a newer API used without the availability the target requires.
- A native module added to the Mac host without updating the autolinking assertion in `apps/macos/scripts/verify-bundle.ts`.

#### Tests in the same change

Apply `docs/agents/testing.md`'s admission and proportionate-verification policy: existing meaningful coverage may suffice; document unavailable automation or protected/native evidence with its required follow-up. The cases below identify missing evidence for a named risk, not a requirement to add a test for every edit.

- A native protocol/API signature change or merge accepted with compilation evidence that omits a consumer target. Inventory every caller and conformer, including integration probes and runner-only sources outside the Swift package and app targets, and map each to the command that compiles it. For `GoogleRegistrationProvider.gmail`, include `integration/SyntheticMetadataTests.swift` through `native/private-inbox/integration/metadata.zsh`; `swift build --build-tests` and a Sources-plus-bridge typecheck do not compile that probe. Run the affected compilation commands or report them as deferred; a caller search identifies coverage but is not compilation evidence. Otherwise a locally passing merge can leave the dedicated integration script or hosted native runner unable to compile. This checks validation scope, not compiler diagnostics already owned by tooling.
- Changed storage, key or registration behavior with no Swift test in `native/private-inbox/Tests` or the on-device suite in `native/private-inbox/integration`. Package tests do not prove real Keychain or file-protection behavior on a device; say which evidence exists and which is deferred.

#### Leave to tooling

swift-format and SwiftLint findings, compiler diagnostics and Xcode analyzer results. The merged Swift and Objective-C rules cover language-level ownership, concurrency and error handling; apply them to runtime-derived values, not to fixed fixtures.
