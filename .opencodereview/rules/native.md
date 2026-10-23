Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to the replacement's native code: `native/private-inbox` (Swift package and React Native bridge), `native/localization` and the AppKit host in `apps/macos/macos`.

Native storage owns what TypeScript must never hold: Keychain items, the storage encryption key, Private Sync account-key material, sign-in tokens and file protection. The bridge is the only path between it and JavaScript. The replacement targets iOS, iPadOS and macOS 27.

#### Error reporting lifecycle

- `ReportingDocument.decode` or `ErrorReportingStore.load` treating a present
  malformed nested document as fresh idle before native collector startup. Validate
  its complete shape, version, bounds and report fields against the shared contract,
  including excess keys and explicit null optionals, before collection or persistence.
  Distinguish absent state and valid expired reports from malformed state. Stop/cancel
  collection and fail unavailable without rewriting consent, pending deletion,
  identity or deletion credentials; otherwise startup can collect before the shared
  decoder rejects it or corrupt storage can erase deletion authority.
- `ErrorReportingStore.disableForAccountRemoval` acknowledging withdrawal after
  both consent persistence and a new marker write fail. Require successful
  disabled custody or a freshly written wildcard withdrawal marker; an older
  marker can predate the enabled generation. Propagate failure through
  `stopErrorReporting`, `recordRemoval`, `endSession` and `purge` before account
  mutation, while stopping collection immediately and preserving the independent
  deletion credential. Otherwise cleanup succeeds and restart restores reporting.
- `ErrorReportingStore.save` or `load` allowing a durably pending deletion to
  collect before the shared withdrawal bridge completes. Treat that document as
  a collection gate and purge both queues. Atomically disable and advance the
  generation on the first pending save even when already off, reject pending
  enables, and fence older idle saves as well as enables before withdrawal or
  reopen. Otherwise queued old work can restore collection or erase the intent.
  Preserve intent when purge rejects after the generation commits; otherwise
  termination can resume collection or lose deletion.
- `SentryReportingCollector.project` truncating SDK wire-ordered frames from the
  front. Check the pinned converter's order and retain the innermost 64 without
  reversing again. Verify distinct SDK frames beyond the limit in serialized
  order, including the crash site; otherwise truncation removes diagnostic and
  grouping evidence even though a count-only projection test passes.

- `ErrorReportingStore.read` treating a transient unreadable Keychain as durable
  withdrawal. Stop/cancel collection and fail closed during the failure, then
  recover stored consent without advancing its generation after a successful
  read. Preserve explicit withdrawal markers and failed-write blocking across
  lock/unlock and restart; otherwise a background read silently opts a person out
  or availability recovery resurrects revoked reporting.

- `ErrorReportingStore.request` transmitting a fresh installation's capability for
  revoke, delete or status when it never opted in. Use durable `everEnabled`, not
  an empty queue, to establish prior reporting authority. Complete never-enabled
  deletion locally without registering an installation. Preserve actual opted-in
  remote deletion and deletion credentials across account purge, and keep
  the generation/withdrawal marker effective through failed Keychain writes. Require
  the observed generation on bridged enables so a late enable cannot undo a later
  withdrawal;
  otherwise opting out itself registers an installation or a restart restores consent.
- `SentryReportingCollector` allowing any SDK HTTP request, including close's flush,
  forwarding an SDK dictionary instead of its approved projection, or starting when
  the per-platform qualification flag is false. Check the disconnected session,
  beforeSend drop, raw-cache purge and late generation callbacks together; otherwise
  native reports bypass the consent or safe-payload boundary.

#### Bundled localization resources

- `UnwiredLanguagePreferences.catalog` relying on a Debug assertion before using
  missing or invalid catalog data. Handle failed reads and JSON parsing before
  Foundation calls that reject nil; cache failure without inserting nil into a
  collection, and preserve `UnwiredNativeText`'s English fallback. Otherwise a
  missing translation resource crashes Release instead of falling back. Verify
  the failure path with assertions disabled, including repeated cached lookups.

#### Keys, credentials and storage

- `RegistrationStore.imapOpen` or another bounded credentialed acquisition
  checking capacity only after authentication. Refuse an already-full owner
  before opening or logging in, and trace production callers across suspension:
  preserve serialization or reserve capacity when concurrent admission requires
  it. Recheck retained capacity after awaited acquisition and close a refused
  result; otherwise refused work still authenticates or concurrent opens exceed
  the owner's handle bound. Verify refusal creates no additional authenticated
  session through the controlled provider.

- `SwiftMailImapSession.folders` returning a truncated LIST as successful, or accepting
  wildcard fallback after an advertised namespace lookup fails. Preserve complete
  namespace coverage and reject overflow or unresolved discovery through the
  existing failure boundary before publishing a listing used for retirement.
  Exercise overflow and failed discovery through the controlled TLS fixture;
  otherwise still-existing folders and their saved bodies can be deleted.

- `SwiftMailImapSession.folders` claiming a response-count bound from a prefix applied
  after SwiftMail's LIST handler collects all responses. Trace admission in the
  pinned upstream handler and parser; per-response byte limits do not bound the
  accumulated collection. Require a receive-time count limit and controlled TLS
  flood evidence when the upstream API supports it. SwiftMail 1.16.0's missing
  public bound remains tracked in #888; a smaller returned array does not resolve
  that native-memory risk.

- `SwiftMailImap.headers` claiming an aggregate receive bound from the requested
  UID count or TypeScript chunk size. Trace the pinned FETCH handler's collection
  of unsolicited and repeated replies as well as requested messages. SwiftMail
  1.16.0's aggregate receive gap is an owner-accepted residual risk for PR #1185,
  tracked in #1187, not a delivery blocker for that PR. When implementing #1187,
  bound retained response count and bytes before the bulk result materializes;
  per-FETCH literal limits, parser working-buffer limits and post-return filtering
  do not bound the command's accumulated results. Exercise extra replies through
  the controlled TLS fixture, including multiple individually legal sections in
  one response. Verify real wire refusal and its fixed bridge error, rather than
  inferring protection from a parser option or synthetic handler events; otherwise
  automatic prefetch can exhaust native memory before any exclusion marker is stored.

- `SwiftMailImap.synchronize` estimating arrivals from the whole folder minus
  cached flags alone, or from the UIDNEXT gap alone. Bound extant arrivals by
  both when UIDNEXT is known, preserving the unknown-UIDNEXT fallback; old
  uncached messages and expunged arrivals otherwise cause repeated envelope
  relisting. Exercise a large unchanged folder and a small folder with a UID gap
  through the controlled TLS fixture.

- `SwiftMailImap` accepting SwiftMail's default zero UIDVALIDITY when EXAMINE
  omits it. Require nonzero validity before any FETCH, including verification,
  synchronization and body reads; exercise omission with the controlled TLS
  server. Otherwise repeated default identities can reuse a different message's
  encrypted cached body.

- `SwiftMailImap` trusting RFC822.SIZE or checking a fetched body only after the
  upstream parser buffered it. Bound body literals and response attributes in the
  real engine parser before accepting payload bytes, with a controlled TLS server
  declaring an oversized literal without sending it; otherwise an untrusted server
  can exhaust native memory before the application size check runs.

- `DeviceRevocation.proposal`, `confirmRevocation` or another removal-status path
  reporting `removed` or `superseded` from roster absence, a conflict or lost-key
  cleanup alone. Require an exact committed proposal receipt or a definite backend
  target-removal result; a Trusted Device row can disappear through sign-out or
  authorized reenrollment while its replacement stays trusted. Trace the shared
  `revocationNotice` mapping and host copy, including conflict renewal and submitted
  replay after private-key loss; otherwise the interface claims removal of a device
  that retains access, or presents an uncommitted Recovery Key as current.
- `PrivateInboxStore.openRemoteContent` refreshing remote-cache recency on read.
  Reads can be rejected later by TypeScript's display admission; update recency
  only through the owning reader's explicit shown-content operation, under the
  same file lock and mailbox/protected-data fences. Otherwise undisplayed entries
  displace genuinely used images during least-recently-used eviction.

- `PrivateInboxStore.fullSync(_:)` or another durability helper treating failure
  of a stronger guarantee as permission to succeed through a weaker fallback.
  Restrict fallback to the platform's documented unsupported-operation errors,
  retry interrupted calls and inspect their failure code before another operation
  can overwrite it. Propagate real I/O and other failures before publishing success;
  otherwise a failed drive-cache flush can be reported as a durable mutation.

- `DraftSync.push` mapping every failed expected-revision write to a conflict.
  Only the coded conditional-write refusal, reconciled with authenticated record
  absence, can become `committed: false`; preserve transport, cancellation and
  other failures even when the record is absent. Otherwise synchronization hides
  failed backend operations as concurrency, suppressing diagnostics and recovery.

- `PrivateInboxStore.importDraftAsset` applying process-wide pending-import protection
  to bytes downloaded for an already-stored Draft reference. Trace every import caller,
  including `RegistrationStore.storeDraftAsset`: protect picker/received imports only
  until reference adoption or abandonment, while synced downloads rely on the document's
  keep list. Verify that a later stored document dropping the downloaded asset reclaims
  it in the same process, while live/history-held references remain protected.
  Otherwise Discard leaves orphaned ciphertext consuming the non-evicting quota until relaunch.

- `PrivateInboxStore.discardDraftAsset` retaining process-local import protection
  after an abandoned import's file removal throws. Release that protection under
  the storage lock on both success and failure, preserving the deletion error,
  so a later save can retry cleanup. Trace `drafts.ts` import settlement and
  discard callers: live imports and committed keep references must remain
  protected. Otherwise failed discards keep orphaned ciphertext against the hard
  quota until relaunch, or premature release deletes bytes still needed by a Draft.

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
- Native database keys, Private Sync account-key material or provider/device credentials returned across the bridge. The intended local presentation payloads are permitted: decrypted Inbox snapshots and registration display fields, including the user-held Recovery Key during setup (`RegistrationSnapshotSchema`). None may enter logs, crash annotations, unprotected persistence or plaintext temporary files; temporary storage writes hold ciphertext only.
- A new key generated when the expected one is missing on an initialized account. A missing account key requires trusted-device approval or the current Recovery Key. A missing bound device private key requires a fresh Pending Device installation and authorization, even when the old ring remains; never replace the immutable public key on its old registration. Otherwise sign-in fabricates usable key custody or reenrollment remains stranded.
- `RegistrationStore.reenroll` or another destructive reenrollment/cleanup path
  discarding a vault with an unconfirmed Recovery Key or a submitted removal
  before its exact outcome is reconciled. Preserve the sole backup and durable
  proposal locator, including after device-private-key loss; retaining them must
  not permit ordinary Private Sync writes, enrollment decisions or new removals.
  Trace `draftSync`, `approveEnrollment`, `declineEnrollment` and revocation
  confirmation/cancellation: exact submitted-intent replay may reconcile its
  receipt and locally retained proposal envelope, but fresh enrollment remains
  required before ordinary use. An absent receipt retains intent, and a later
  superseding rotation cannot make that proposal's Recovery Key current.
  Explicit account deletion and credential-proven revocation purge retain their
  destructive cleanup contracts.
  Otherwise cleanup loses recovery access, or its guard strands reconciliation
  or silently preserves keyless Trusted Device privileges.
- Ciphertext written without atomic replacement and file synchronization before the call resolves, without complete file protection on iOS, or into a directory included in backup.
- A read-modify-write, including first-run seeding, performed outside the native file lock, or that rewrites more than the requested record from a stale in-memory copy.
- AES-GCM used with a reused or predictable nonce, or a failed authentication treated as empty data rather than an error. Private Sync records and envelopes must retain their purpose-specific account, record/request/device, schema and epoch binding in `ProductSyncSeal`; the separate synthetic Inbox fixture retains its `dev.unwired.private-inbox.v1` context and is not account-scoped Private Sync storage.
- Filesystem access on iOS before the protected-data availability check, or a locked device reported as a generic failure rather than `locked`.
- Cleanup of old keys, envelopes or credentials ordered before the replacement is durably adopted.
- A revocation purge such as `RegistrationStore.purge` that stops account-item cleanup at the first failure, clears in-memory authorization only after a throwing read, or deletes the registration/retry locator before every dependent item is removed. Attempt every known item, retain the first failure and remove the locator last; otherwise credentials remain live in memory or a partial purge loses its account scope and cannot resume.
- Native `recordRemoval` or `purge` weakening durable removal intent or acknowledgement before cleanup. The TypeScript registration flow owns remote sequencing; native storage must retain the acknowledged operation and retry locator until every dependent item is removed. Sign-out preparation must reconcile rotation and protect any unconfirmed Recovery Key instead of discarding its sole backup.

#### Bridge contract

- `UnwiredNotifications.postNotifications` admitting a captured preview or
  connection solely from its provider-derived local identifier. Recheck the
  originating Product Account, connection incarnation and current preview
  consent inside the registration gate; serialize preview opt-out with posting
  so acknowledged withdrawal cannot precede a queued content-bearing alert.
- Notification cleanup attached only to an exported bridge wrapper. Trace
  `RegistrationStore.purge`, connection cleanup and session end, including
  revocation discovered by mailbox preflight; every native entry point must
  withdraw its delivered alerts, or removed-account previews stay visible.

- `Measurement.Sampler` or another native owner using an `unowned` capture in
  an escaping timer, task or queue callback. Trace every queue hop through stop,
  cancellation and owner release, including the outer timer handler. Cancelling
  the source does not drain already-enqueued work; require weak ownership or a
  proven lifetime covering every callback, or dismissal can crash after release.

- `RegistrationStore.registration` projecting independently saved Profile state
  only inside `productSyncState`'s key-dependent result. A sibling key failure
  must not erase retained ownership or replay floors: project saved Profile state
  independently and distinguish unreadable bytes from absence. Trace the native
  reply, TypeScript schema and synthetic projection, and test malformed keys and
  malformed saved Profile bytes separately; otherwise unreadable keys silently
  reassign moved connections to Default or lose confirmed removals.

- `RegistrationStore.productSyncState` or another native projection retaining
  sensitive presentation fields after their display state ends when status
  derivation moves to TypeScript. Preserve the native field's state gate across
  the move: a retained full Recovery Key crosses only while unconfirmed, even
  when JavaScript hides it after confirmation. Trace the stored state, raw bridge
  projection and synthetic vault together, and require a regression assertion
  against the raw projection after the transition. Otherwise a hidden secret
  still enters the JavaScript heap outside its permitted presentation window.

- `assistance.ts` input builders or `UnwiredAssistance` model prompts using flat
  labelled concatenation instead of a typed JSON request with an explicit
  operation and distinct fields for each admitted context source,
  as required by ADR 0052. Quoted labels or field names must remain escaped data,
  never authored intent or framing. Measure the complete encoded payload against
  the input bound, preserve full admitted authored text, surrogate-safe cuts,
  cut-word address removal and omission disclosure, and keep fixed native
  instructions aligned with the fields. Otherwise adversarial correspondence
  can impersonate the person's reply or escaping can exceed the model budget.

- `UnwiredAssistance` summary generation or `assistance.ts.decodeSummary`
  treating a serialized request/response object as readable summary prose.
  Check the native output instructions and shared decoder together: internal
  JSON fields must not become a successful preview, while legitimate quotation
  marks, braces, escaped characters and paragraph breaks remain intact. Require
  the documented failure state for unsupported output and real on-device model
  evidence for prompt changes; a fixed mock summary cannot establish the output
  format. Otherwise the Summary card can expose protocol fields despite accepting
  a valid string at the native boundary.

- `RegistrationStore.readDraftAsset` returning full decrypted image bytes as a
  base64 URI merely to show a composer thumbnail, or decoding previews on the
  main actor. Keep verification and thumbnail work off-main, return bounded
  presentation pixels, and trace `UnwiredRegistration.mailbox`'s operation gate
  across the awaited read so several rows/windows do not multiply full-byte
  working sets. Preserve original encrypted asset bytes, owner/protected-data
  fences and explicit no-thumbnail success in the shared `drafts.ts.readAsset`
  decoder; malformed replies still fail closed. Otherwise permitted large images
  can exhaust memory on composer opening or valid assets appear damaged.

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
- `GmailTransport.failure` or `RegistrationStore.gmail` collapsing definite
  pre-handoff transport failures and possibly delivered sends into one error.
  Admit an error to the unsent classification only when its transport contract
  proves no request body could have reached Gmail; interrupted uploads, lost
  replies, cancellation and response overflow retain an unknown send outcome.
  Preserve ordinary unavailability for reads and label modifications and the
  fixed `rejectMailbox` codes. Otherwise offline sends lose their queued retry
  and Edit path, or an ambiguous send is submitted twice.
- `RegistrationStore.graphCall` or another credentialed provider mutation using
  only process verification or the permissive `prepareMailbox` cache preflight.
  As `RegistrationStore.gmail` does, require a current credential-only
  `deviceRevoked` proof before provider renewal, reject an unavailable or absent
  proof, purge positive revocation, and recheck ownership after suspension.
  For Gmail and Graph sends, retain that pre-renewal proof as well as the fresh
  post-renewal proof immediately before handoff; replacing the first with the
  second still renews provider access for an already-revoked device. Exercise
  already-revoked sends with zero credential refreshes and revocation during
  refresh with zero submissions. Otherwise queued writes can reach the provider
  while device trust is unknown or after remote revocation. Cache reads retain
  their separate offline policy.
- A positive revocation found by `RegistrationStore.prepareMailbox` converted to ordinary mailbox invalidation after successful purge. Trace both `UnwiredRegistration.openMailbox` and `commitMailbox` through the shared rejection mapper and `createGmailInbox` recovery: preserve `mailbox-revoked` and its account-page hand-off, while generation changes retain bounded invalidation recovery. Collapsing the two makes already-purged mail end in retry exhaustion and a generic failure instead of the removal explanation. `UnwiredRegistration.syncDrafts` must likewise preserve both revoked and deleted account rejections through `rejectMailbox`; registration restore retains the deletion notice. Mapping deletion to ordinary unavailability leaves shared Draft state open after native account purge.
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
- A rejection code the owning TypeScript consumer cannot handle. Trace bridge
  codes through `registration-flow.ts` and its `hostCodes` mapping before the
  store derives diagnostics; flow-internal codes such as `offline` may become
  an existing host code. A code that reaches diagnostics must be allow-listed in
  `packages/mail-core/src/diagnostics.ts`; otherwise recovery can be misclassified
  or an expected refusal loses its useful fixed diagnostic.
- A rejection or diagnostic that carries a foreign error description, account identifier, email address, token or path. JavaScript logs can leave the device; reject with a fixed code and fixed text, as `UnwiredPrivateInbox.perform` does. Successful values may contain the documented local presentation data consumed by the shared store; they must not be logged.
- A resolved payload whose shape changed without the `Schema` that decodes it in `mail-core` changing with it.
- A promise that can resolve twice, never resolve, or resolve after its owner is gone; blocking native work on the main queue that demonstrably stalls the UI. Registration presentation is `@MainActor`; that annotation alone is not a defect.
- A security decision moved to JavaScript: token validation, nonce and expiry checks, identity matching, lock state. The native host decides; TypeScript decoding complements it.
- A method exported to JavaScript that performs a privileged action on arguments it does not validate.

#### Identity and registration

- A saved Trusted Device operation whose TypeScript caller bypasses `createRegistrationFlow.guarded` and its credential-only revocation check before provider renewal, an interactive prompt or other user-cancellable work. Registration sequencing moved out of `RegistrationStore` in #756; do not require native operations to duplicate the flow guard. A failed refresh/grant check or cancelled prompt must not suppress credential-proven revocation and leave account credentials and keys on a removed device. Apple cannot silently renew Product Sign-In after relaunch; provider credential state alone proves no device trust. A positive backend rejection must purge account credentials and keys before later provider access, while transport unavailability retains the owning resumable/offline state.
- An identity token accepted without the expected issuer, audience, subject and expiry checks, or an interactive sign-in result accepted without its session nonce check. SDK token refresh follows its owning refresh boundary; it does not reuse an interactive nonce requirement. Claims trusted after only client-side parsing where the backend must verify are also a defect.
- State from one Product Account, sign-in provider, device or deployment reused after any of them changes; an enrollment or recovery step that proceeds on a stale epoch or a stale authentication.
- Recovery Key verification that sends the key, an envelope encryption key or any derived secret beyond ADR 0066's explicit purpose-specific admission proof off the device, or a rejected key that leaves the device without its current enrollment status.
- A recent-authentication requirement removed from an operation that needs it.
- A rotation sealed with an earlier shared account key or an enrollment/recovery secret the removed device held. Follow ADR 0070: seal the complete ring with HPKE independently to every surviving Trusted Device's bound key, including the initiator, and authenticate account, exact recipient/key, epoch and protocol version. Never omit an unbound survivor. Otherwise backend read access plus removed secrets exposes the removal epoch or strands a survivor.
- `RegistrationStore.confirmRevocation` or `cancelRevocation` treating a tombstone, current epoch or duplicate success as proof that this proposal's Recovery Key is current. Use the freshest exact durable proposal receipt observed during adoption, including when a lost device key permits restoring only the original proposal's ring. Its recovery-current result must also agree with the latest durable epoch after subsequent synchronization; a newer observed ring supersedes its earlier current-key result. Unreadable local state cannot justify that assertion or reject an already settled removal. Otherwise an old confirmed key is presented as current recovery access.
- `RegistrationStore.confirmRevocation`, `cancelRevocation` or `adoptRotation`
  rejecting after durable adoption has cleared the proposal because a follow-up
  remote read or adoption acknowledgement failed. Complete fallible reads needed
  for the result before that local transition; keep post-adoption acknowledgement
  failures nonfatal and retry them during later synchronization, while preserving
  revoked/deleted rejections and purge. Exercise Confirm and Cancel with failures
  at those boundaries. If a native or shared-flow status refresh rejected after
  settlement, Confirm/Cancel retries with readable registration but no native
  proposal must allow a notice-free current-state refresh without activation or
  a Recovery Key claim. Otherwise the host retains a proposal whose native locator
  is gone, so neither action can settle it.
- `RegistrationStore.confirmRevocation` clearing a definitely rejected proposal
  before fallible conflict renewal finishes. Retain it as unsubmitted and
  cancellable until the replacement proposal is durable, then require the new
  key's confirmation; clear it when the target is definitively gone. Otherwise
  a failed roster or recovery-record read leaves the old proposal on screen but
  removes its native Confirm/Cancel locator.
- `revoke`, `cancelRevocation` or `prepareSignOut` replacing/discarding a submitted proposal before its outcome and committed ring are durably adopted. An absent receipt cannot rule out an in-flight request, and a definite refusal on a retry cannot settle an earlier unanswered attempt. Preserve the exact request through relaunch, cancellation and failed post-commit adoption. Treat malformed success replies as unknown outcomes. Otherwise interruption loses the sole reconciliation locator or recovery backup.
- Removal submitted before its proposed replacement Recovery Key is saved and confirmed, or a stale proposal renewed without requiring confirmation of the new key. Preparation must not change the backend epoch or ordinary write key; otherwise cancellation removes a device or discarded-key confirmation authorizes different material.

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
- `PrivateInboxStore.commitMessageBody` accepting an IMAP body or exclusion marker
  without checking its metadata revision inside the same file-locked transaction,
  before eviction or replacement. Trace `imap-inbox.ts` admission and every adapter's
  forwarding of `expectedRevision`; a store-local semaphore and `listed` check cannot
  observe another store's committed UIDVALIDITY reset or expunge. Otherwise a late
  prefetch recreates bodies the newer synchronization already pruned. Keep omitted
  revisions compatible with existing callers, but reject malformed supplied values.
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

- `PrivateInboxStore.adoptLegacyMailbox` assuming the connection's body folder
  is absent, or merging by a tier-suffixed filename rather than body identity.
  A body may be saved before metadata adoption; preserve that destination body
  across every supported tier and keep interrupted migration
  retryable. Otherwise cache open repeatedly fails or an older legacy body
  becomes the preferred readable copy.
- `PrivateInboxStore.bodies()` omitting unadopted root `bodies/` from device-wide
  admission and eviction totals. Count every supported layout until adoption or
  removal; moving legacy bodies under `mailboxes/<id>` must count them once.
  Keep `bodies(connection)` and list/membership pruning connection-scoped, and
  preserve legacy metadata during body eviction. Otherwise legacy mail adds a
  second cache quota or pruning destroys another connection's pending actions.
- `removeMailbox` or synchronized descriptor purge deleting caches before durable
  credential removal and retry recording, returning a stale connection list after
  later failure, or omitting an unopened legacy root cache. Trace cleanup through
  `SavedRegistration` and `retryMailboxCleanup`: preserve owner-specific keyless
  legacy cleanup, attempt every owned path, and keep failed cleanup retryable without
  reopening the connection. Otherwise partial cleanup retains credentials/plaintext
  or loses another connection's durable pending actions.

#### Gmail push lifecycle

- `RegistrationStore.unroute`, watch routing or stopping dispatching by subject
  alone instead of the connection's provider. Microsoft removals must not call
  Gmail watch or relay cleanup, even when synthetic provider subjects coincide;
  otherwise cleanup reaches the wrong provider or records unrelated relay work.
- `GraphMailProvider.verified` or `exchange` reducing unsent or interrupted
  transport failures to an authorization refusal. Preserve the retryable offline
  code consumed by `registration-flow.ts.mailboxStatus`, while keeping definite
  rejected grants distinct; otherwise a transient outage closes saved mail and
  asks for consent that cannot repair connectivity. Exercise the production
  transport's fixed rejection code alongside the shared restore journey.

- `RegistrationStore.relay` constructing a `BackendRequest` with device proof
  alone when its Convex handler also requires Product Sign-In. Trace
  `BackendRequest.identity` through `UnwiredRegistration.send` and the handler's
  authentication helper, including native token callbacks after Apple relaunch.
  Keep required credentials native and unavailable routing retryable; deterministic
  transport fixtures must not substitute for the missing bearer identity.
  Otherwise production route registration and cleanup fail authentication while
  their mocked journeys pass, leaving wakes unavailable or stale routes retained.
- `UnwiredPushWakes.registerDeviceToken` retaining a new or rotated APNs token only
  in memory after routing already ran. Queue authenticated registration under
  `RegistrationOperationGate` when the token arrives, including first-launch
  arrival after restore and rotation with no process-verified mailboxes but saved
  routes. Otherwise the relay continues targeting an old or absent token until
  another activation and background mail loses its wake.
- Native-initiated token routing in `RegistrationStore.pushDeviceChanged`
  restarting watches after `stopMailboxWatches` or during durable account removal.
  The native gate serializes individual operations, not the shared flow's entire
  removal sequence; fence callbacks from the start of watch stopping until a later
  verified routing resumes. Handle structured revocation/deletion through the same
  local purge before releasing custody. Otherwise a callback recreates a watch
  whose credential teardown discards or retains access after definitive rejection.
- `RegistrationStore.pushDeviceChanged` purging local custody without handing its
  fixed revoked/deleted rejection to `registration()` until the shared flow
  acknowledges it. Successful purge deletes the saved record, so retain only a
  process-local rejection for that handoff; otherwise the next shared operation
  loses the removal notice or keeps a stale connected account view.

- `RegistrationStore.watch` or `stopWatch` using a refreshed Gmail credential
  without matching its subject to the connection's saved receipt. Check identity
  before the provider request; otherwise a mismatched saved credential can create
  or stop another mailbox's watch.

- `RegistrationStore.removeMailbox` deleting its relay row before the Private Sync
  removal is acknowledged. Queue the opaque locator alongside durable local
  removal intent and flush after acknowledgement or a superseding incarnation;
  otherwise a crash can delete the route without a synchronized removal.
  Learned synchronized removal stops the watch before discarding its credential.

- `RegistrationStore.unroute`, `stopMailboxWatches` or synchronized descriptor
  purge requiring a saved `pushRoute` before cleanup. Relay registration and
  Gmail watch creation can succeed before verification fails; check cleanup with
  no local route and stop the watch while its credential remains available.
  Otherwise removing that mailbox loses the only watch-cleanup credential and
  leaves its operational relay registration behind.
- `stopWatch` retaining current watch expiry after an allowed stop, including an
  unanswered provider request. Invalidate coverage durably before the stop;
  a later sign-out/deletion refusal must permit immediate renewal and fallback
  polling rather than leave an active account relying on a stopped watch.
- `mailboxRoutes.complete` ignoring the relay's `verified` response or a changed
  APNs token. Pending proof does not establish push coverage. Keep the pending
  opaque route available for a late wake, retry proof at a later verification,
  and suppress fallback polling only for registered, proven, current routes.

#### Remote content retrieval

- `RemoteContent.swift` classifying a NAT64 destination only by its globally
  routable IPv6 prefix or the prefixes discovered through `ipv4only.arpa`.
  RFC 7050 discovery cannot learn destination-specific prefixes for private IPv4.
  Apply ADR 0029's 2026-10-10 amendment: check every RFC 6052 layout for globally
  formatted IPv6, including the reserved-byte split and nonzero suffixes, and
  preserve the well-known prefix's embedded-IPv4 guard for every literal,
  resolved answer and redirect. Definitely non-public answers refuse the whole
  name; ambiguous globally formatted IPv6 answers are discarded and never connected
  to. Pin the first remaining admitted answer and refuse if none remains. Trace
  the numeric transport endpoint: it must never re-resolve or fall back to an
  unchecked answer. Cover both answer orders, mixed definitely non-public answers,
  redirects and IPv6-only refusal, and keep the remaining compatibility cost
  documented. Otherwise discovery or unchecked fallback permits private access,
  or ambiguous AAAA records unnecessarily block admitted dual-stack destinations.

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

- `AppDelegate.mm.openWindowWithProfile` passing a restored Profile only to its
  React root while `willEncodeRestorableState` reads a separate native map. Seed
  native restoration state when constructing the window, before JavaScript or
  registration can run; otherwise quitting while storage is locked loses the
  restored choice. Keep real AppKit relaunch evidence separate from host tests.

- `UnwiredDesign.m` menu migration dropping a localized accessibility label when
  building `NSMenuItem` titles. Preserve the visible title and the separate
  accessible name, including Writing tools' whole-body versus selected-text
  scope. Check the item payload, AppKit property and native journey locator
  together; otherwise VoiceOver loses the operation's target while component
  tests that choose only by visible title still pass.

- `AppDelegate.mm.installMenus` omitting standard text-editing menu items or
  targeting them at the app delegate. Trace Cut, Copy, Paste and Select All key
  equivalents through AppKit's focused responder and menu validation, in both a
  controlled TextInput and the composer body; an editable control alone does not
  provide these shortcuts, so typing can work while Command-X/V does nothing.
  Preserve the documented omission of native Undo/Redo: a controlled field's
  stale AppKit undo stack can corrupt text, while the composer owns its history.

- `AttachmentPresenter` installing a controller only through `NSResponder.nextResponder`
  or a Quick Look data source, both unretained references. Give each window's
  controller an explicit strong owner through its active lifetime; on close,
  restore owned responder links, detach its panel data source and release its
  observer and owner. Check identities before teardown so another window's preview
  remains intact; otherwise AppKit messages a dangling controller or a closed
  window retains presentation state indefinitely.
- `UnwiredCommands.saveFocus` keeping a responder from an earlier opening when
  the window's current first responder is not a view, or `restoreFocus`
  focusing a saved view without checking it is still in that window. Fabric
  recycles a removed component view and mounts it elsewhere, so a weak
  reference outlives the control it named, and a palette that left with its
  screen never cleared its entry. Clear the window's entry on every save;
  otherwise closing a later palette focuses an unrelated control.
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
- A native module added to the Mac host without updating the autolinking
  allowlist in `apps/macos/scripts/verify-native.ts` or preserving the renderer
  boundary in `apps/macos/scripts/verify-bundle.ts`. Review its tracked native
  lockfile under `.opencodereview/rules/workspace.md`; otherwise the build can
  include an unreviewed module or dependency graph.

#### Tests in the same change

Apply `docs/agents/testing.md`'s admission and proportionate-verification policy: existing meaningful coverage may suffice; document unavailable automation or protected/native evidence with its required follow-up. The cases below identify missing evidence for a named risk, not a requirement to add a test for every edit.

- `integration/test.zsh` accepting a completed Swift Testing run only at a fixed
  historical test count. Require successful `xcodebuild` completion and a
  positive completed test total, retaining empty-run and failure rejection.
  Verify that adding a test still completes without retry; otherwise a passing
  suite runs again against stateful protocol fixtures and falsely trips their
  duplicate-delivery guards.

- A native protocol/API signature change or merge accepted with compilation evidence that omits a consumer target. Inventory every caller and conformer, including integration probes and runner-only sources outside the Swift package and app targets, and map each to the command that compiles it. For `GoogleRegistrationProvider.gmail`, include `integration/SyntheticMetadataTests.swift` through `native/private-inbox/integration/metadata.zsh`; `swift build --build-tests` and a Sources-plus-bridge typecheck do not compile that probe. Run the affected compilation commands or report them as deferred; a caller search identifies coverage but is not compilation evidence. Otherwise a locally passing merge can leave the dedicated integration script or hosted native runner unable to compile. This checks validation scope, not compiler diagnostics already owned by tooling.
- Changed storage, key or registration behavior with no Swift test in `native/private-inbox/Tests` or the on-device suite in `native/private-inbox/integration`. Package tests do not prove real Keychain or file-protection behavior on a device; say which evidence exists and which is deferred.

#### Leave to tooling

swift-format and SwiftLint findings, compiler diagnostics and Xcode analyzer results. The merged Swift and Objective-C rules cover language-level ownership, concurrency and error handling; apply them to runtime-derived values, not to fixed fixtures.
