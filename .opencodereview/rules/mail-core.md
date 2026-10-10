Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to `packages/mail-core`.

`packages/mail-core` holds the shared application logic as Effect programs behind framework-independent stores (`getSnapshot`, `subscribe`, Promise-returning actions). The iOS/iPadOS Hermes bundle and the React Native macOS bundle both compile this source, so a mistake here ships to every host.

#### Dependency direction

- An import of `react`, `react-native`, `expo*`, `convex`, a `node:` built-in or anything under `apps/`. Hosts own views and native adapters; the Mac bundle check rejects the mobile renderer, and a UI import here forces incompatible renderers together.
- A production module that imports from `src/testing/`. Metro substitutes those modules only for a named Mock Mail Session scenario (`scripts/mock-mail-build.cjs`); a static import carries synthetic providers into release bundles.
- A module hosts need that has no subpath in `package.json` `exports`, or a host reaching it through a relative path into `src/`. The exports map is the package's public interface.
- Native capability passed in as a concrete module rather than as an interface the host supplies (as `NativeInboxStorage` is supplied to `createPersistentInbox`). The interface keeps the store testable with real logic and a substituted boundary.

#### Shared runtime compatibility

- Named-capture extraction in `drafts.ts.recipientOf`, `gmail-inbox.ts.sender`,
  `message-body.ts` or another shared parser that assumes `.groups` is present on
  `exec`, `match` or `matchAll` results in code bundled for Hermes. A host's Babel
  named-group transform can leave `.groups` unset while positional captures
  survive and Node tests pass, rejecting valid named recipients, retaining a
  whole From header as an address or dropping message content and link destinations.
  Read positional captures while retaining named groups in the pattern for lint;
  exercise absent `.groups` in a regression and validate changed parsing in the
  packaged host when its transform differs from the test runtime.

#### Untrusted boundaries fail closed

- A native bridge result, seed, persisted JSON value, HTTP body, token or route parameter used before a `Schema` decode, or narrowed with `as`, a hand-written property check or a truthiness test. The Apple host's checks do not make its results trusted in TypeScript.
- A decode failure that becomes a default, an empty list or a `ready` state. It must map to the boundary's existing tagged error, with the decode error as `cause`, and surface as a non-ready state.
- A schema widened (`Schema.Unknown`, optional field, loose union) to make a fixture or a new native result pass, without the consumer handling the widened case.
- `assistance.ts.decodeDraftText`, `translation.ts.decodeTranslation` or another
  generated-text decoder admitting content the Draft editor cannot insert as
  reviewed. Validate against `draftReplacement` and
  `semantic-document.ts.replaceSelection` before publishing `ready`, including
  rejecting U+FFFC image placeholders that replacement strips. Otherwise a
  nonblank preview can become an empty insertion and delete captured authored
  text, or the accepted edit silently differs from its preview. Fail closed
  rather than silently sanitizing the generated result; test the public store
  with placeholder-only and mixed-text output.
- `drafts.ts.readAsset` using the verify-only response schema for a requested
  image preview. Require a nonempty URI or the explicit `uri: null` no-thumbnail
  success reply, mapping the latter to verified bytes without a picture. Admit
  the empty native-only verification reply only when preview is false; otherwise a
  malformed preview silently becomes a healthy asset with no image or warning.
- `message-body.ts.decodeFullMessage` recursively decoding an unbounded MIME
  tree before applying traversal limits. Bound depth and total parts iteratively
  before `GmailPartSchema` runs, counting attachment and discarded subtrees too;
  every production body/CID traversal must consume that bounded decode. Check
  inclusive limits and the public unavailable/download failure state, not just
  direct helper rejection. Otherwise Schema decoding itself can overflow before
  a traversal guard, reject the host-facing read and leave the message loading.

#### Errors and diagnostics

- A failure modelled as a thrown `Error`, a string or a boolean where callers need to tell cases apart; use `Schema.TaggedError`, with a foreign error carried as `cause: Schema.Defect()`.
- An expected state (locked storage, cancelled or declined sign-in, enrollment waiting) logged as an error, or an unexpected failure recovered without `Effect.logError`.
- A log, annotation or error message that carries `cause`, `error.message`, `String(error)`, a payload, an email address, a token or an account, device or message identifier. Any field of a host or provider error can hold mail or account data; log only what `rejectionDiagnostic` and `decodeDiagnostic` in `src/diagnostics.ts` produce.
- A new native rejection code handled in a store without being added to `nativeCodes` in `src/diagnostics.ts` (it logs as `unrecognized code` and cannot be diagnosed), or that allow-list widened to pass through arbitrary strings.
- `Effect.catch`/`catchAll`-style recovery that swallows a failure the caller's contract does not permit recovering, or `Effect.orDie` on a failure a user can trigger.

#### Running programs and shared state

- `createGmailInbox.store` or `retainBodies` changing body-cache membership
  without notifying the cache subscribers exposed by `createMailboxes.bodies`.
  Publish after admitted commits and successful pruning, using the coordinator
  shared by every connection: the device-wide budget lets one connection evict
  another's body. Refused admission preserves membership. Otherwise derived
  saved-body status remains stale despite unchanged Inbox metadata.
- `Effect.run*` anywhere except the single run of a host-facing store method through `runLogged`; in particular inside a service method or a callback passed back into Effect. A plain async scheduler may run independent Schedule steps through `runLogged`, then invoke Promise-returning store actions outside Effect; it must abort pending waits and prevent future actions when stopped. This exception does not permit wrapping store actions in another Effect run.
- A helper that combines Promise-returning store methods, such as
  `mailboxes.ts.savedMessageBodies`, wrapping their host-facing runs in another
  `runLogged`/`Effect.run*`. Keep that composition plain async, or compose internal
  Effect programs before one boundary run; otherwise each mailbox starts a fresh
  fiber inside the outer program, losing its inherited context and interruption.
- A host-facing action whose Promise can reject for an expected state. Hosts call actions as `void store.load()`, so a rejection is an unhandled promise rejection; expected failures become snapshot state.
- Overlapping asynchronous store actions that read, change or publish shared state without the store's `Semaphore`, so they interleave a read-modify-write or a slower earlier call publishes over a newer result. Synchronous `getSnapshot` and listener bookkeeping do not require an Effect run or permit. Use `withPermit` to queue and `withPermitsIfAvailable` only where dropping the overlapping request is the intended behavior.
- `draft-sync.ts.createDraftSynchronizer.synchronize` or another shared in-flight
  Promise/flag cleared only after normal completion. Release its ownership in
  `finally` on every exit, including defects and interruption outside typed-error
  recovery, so later requests can start fresh work instead of awaiting a rejected
  Promise forever. Preserve serialization and verify recovery through public
  actions after a rejected pass.
- `draft-sync.ts` automatic activation, load or debounce triggers discarding a
  synchronization Promise that can reject on a defect. Handle automatic rejection
  with allow-listed diagnostics while preserving explicit callers' rejection and
  later-pass recovery; otherwise a subscriber defect becomes an unhandled rejection.
- `draft-sync.ts.pushing` publishing a never-confirmed Draft before its exact
  intent is durable, including a local storage CAS rebase that replaces `synced`.
  Verify the stored entry still matches before the remote side effect, and recheck
  Discard after asset uploads. In `readRecords`/`mergeSyncedDrafts`, an unconfirmed
  intent is neither a confirmed version floor nor evidence that remote absence is
  deletion. Accept competing first records, preserve authored conflicts and local
  Discard, and retry a write that never landed. Do not erase intent on an absent
  pull while another local store may still publish it; tombstones remove unchanged
  intended content and preserve only divergent edits. Otherwise interrupted first
  publication can erase local content, resurrect a Discard or reject the winner
  forever. Exercise lost replies, pre-write failure, competing local writers and
  relaunch through public stores.
- `draft-sync.ts.pushing` using a captured non-null Draft after awaited uploads,
  encoding or intent persistence without rechecking the live account and authored
  content. Stop a superseded write and let the next pass publish the current edit
  or tombstone. Confirmed updates also need durable exact pending payload/version
  evidence beside their confirmed base and replay floor; recognize only that exact
  authenticated publication during merge, retain it while the prior record remains,
  and preserve competing authorship otherwise. Keep one pending payload immutable
  per confirmed CAS, including admission by separate local stores; recover its
  exact durable write before admitting a distinct update, with the account fence
  intact and a new pull before newer publication. Recovery may replay admitted
  content the user has since edited, while Discard directly writes a tombstone
  without replacing pending evidence. Reject late local confirmations that regress
  the floor or erase another pending write, and rebase shared local state after a
  confirmed update loses CAS before deriving a conflict from stale content.
  Exercise Discard, continued editing and reverting to confirmed content during
  held writes, lost replies, pre-commit failures, failed confirmation saves, both
  tombstone race orderings, multiple local stores and relaunch.
  Otherwise this device's own superseded content returns as a conflict copy, even
  when an upload-time guard protects first publication.
- `createRegistration.resume` dropping a foreground activation because the account is unlocked or a pending operation holds the semaphore. Queue every activation's native restore after the current operation, preserving unchanged setup feedback while publishing changed verification or locked results; otherwise unlock retries are lost or a running account remains connected after verification becomes unavailable. ADR 0020 requires foreground Trusted Device revalidation; a locked-storage retry must not exempt unlocked accounts, and native reconnect alone does not prove that revocation rejection purges local state.
- `createRegistration.resume` treating each Mac window's report of one application activation as a separate restore. The windows share one store and AppState dispatches listeners synchronously, so coalesce those reports or give the subscription one application-level owner; otherwise native Product Account and Gmail verification repeats per window and prolongs the busy state. Coalescing must end with that dispatch, not with the pending restore, so a later activation after unlock still queues a fresh verification.
- A successful persisted state published before the native operation has durably completed, with no failure path that restores the previous state. Explicit busy/pending presentation states are permitted, as in `createRegistration`.
- A whole-document CAS conflict in `createGmailInbox` that restarts all synchronization for ordinary concurrent intake, discards newly durable intents, or resurrects an action settled by this operation or another store instance. Review `commitOver`/`rebased` against both the prior base and latest saved pending IDs, including dispatch preparation and settlement, reconciliation, labels and blocked-action resolution. Drop previously known IDs absent from the latest document and revalidate the prepared head before dispatch. Retain newly appended intake IDs in FIFO order, bound rebases, and reject another mailbox/owner before any write; repeated benign intake must not exhaust whole-sync retries or duplicate provider actions.
- `createGmailInbox.dispatch` identifying ownership only by pending/message ID,
  a deterministic attempt ID or attempt age after a CAS race. In `rebasedOnto`,
  preserve saved progress that advanced since the base even when stale
  reconciliation or Discard removed that head; compare the unique prepared
  attempt before provider handoff. Check joining stores, equal or reversed clocks,
  completed failures and Retry/Discard while another request is active. Ownership
  must end on every attempt outcome and survive through settlement, so later
  intent cannot overtake a live write or be hidden by its late result.
- `getSnapshot` returning a newly built object or array when nothing changed. `useSyncExternalStore` compares by identity and re-renders forever.
- `createSyntheticGmail` retaining the previous mailbox's user-label catalog on
  reselection, or allocating a new label from the current map size. Clear the
  catalog with the selected mailbox and keep label IDs monotonic across deletion;
  otherwise isolation journeys leak old labels and a pending action for a deleted
  label can incorrectly succeed against its replacement instead of being refused.
- `subscribe` that does not return an unsubscribe removing exactly that listener, or a publish path that skips listeners after a state change.
- A `ManagedRuntime`, fiber, timer or subscription created without an owner that disposes it; a `ManagedRuntime` created for a Layer with no dependencies or resources.
- A retry or poll without a bound, or built from `setTimeout`/recursion rather than `Schedule`.

- `createMailboxes` binding ownership only to account, connection ID and address
  while ignoring a removed/recreated connection's incarnation. Compare the native
  registration epoch and cache owner; immediate replacement must forget old
  plaintext and unsaved actions even when consent returns the same Google mailbox.
  Otherwise stale work survives a synchronized removal and new authorization.
- `createMailboxes` sharing body-load permits while each `createGmailInbox` retains
  a separate image presentation budget. Sum reservations across all connections
  and readers, distinguish same provider IDs in different owner ledgers, and release
  only the affected owner on forget. Otherwise multi-mailbox Mac windows multiply
  the decoded-pixel/encoded-byte bound or one removal uncharges another live reader.

- `drafts.ts.readAsset` swallowing `mailbox-revoked` from lazy Product Sync asset
  downloads as an incomplete-file fallback. Hand the same-account rejection to
  registration just as record synchronization does, while fencing earlier-account
  results by generation; otherwise native purge leaves the host showing private
  Drafts under a stale connected account. Exercise the real registration and Draft
  stores together and assert the closed Draft state, not only a removal callback.

#### Services

- A `Context.Service` introduced where no caller needs a replaceable dependency; a value a closure already owns stays a plain value.
- A service whose dependencies are acquired inside methods rather than once in `make`, whose shape is forced with a type assertion rather than inferred from the returned `as const` object, or that has no static `layer`.
- A service identifier that does not follow `@private-email/<package>/<Name>`; identifiers key the context, and a collision silently resolves the wrong service.

#### Product behavior the stores own

- `gmail-inbox.ts.rejectionOutcomes` or another Send outcome mapper treating a
  pre-request `mailbox-invalidated` refusal as a terminal delivery failure.
  Ordinary foreground verification can renew the native generation while Outbox
  processing uses the previous one. Keep this definite non-delivery queued with its
  held claim, and recheck removed, unauthorized or renamed senders before retry.
  Trace native `gmailSend` and `gmail(sending: true)` before changing this mapping:
  after a request may reach Gmail, preserve its answer or an unknown outcome,
  never infer safe resubmission from a later generation change. Otherwise an
  ordinary refresh reports Not sent, or an uncertain handoff sends twice.
- `outbox.ts.handOff` or another durable provider-outcome transition ignoring a
  refused storage write. Preserve a known answer for storage-only recovery while
  its entry remains handed off; never repeat provider submission merely to record
  that answer. Exercise queued non-delivery, confirmed success and unknown
  outcomes, repeated storage refusal and a competing writer. Clear remembered
  outcomes when their entries disappear or advance, on account invalidation and
  disposal, including late completion after disposal; otherwise safe non-delivery
  stays stranded as unknown or old delivery identifiers remain in memory.
  A recovering writer may conservatively save `unknown` while the live handoff
  still awaits Gmail: that state must not erase the live owner's definite answer.
  Only the instance that performed this handoff may upgrade it from its received
  or retained outcome; a recovering instance without that answer cannot resend.
  Exercise both orderings of the recovery save and the provider answer.
- `outbox.ts.send` or another admission check validating mutable eligibility only
  before awaited asset reads or preparation. Repeat every applicable refusal check
  after the await and before admission, preserving the frozen content and live
  editor binding. Exercise mailbox rename/removal/authorization changes during
  verification; otherwise an unavailable sender or invalid Draft is admitted and
  its composer closes despite Send's refusal contract.

- `drafts.ts.sendingStateOf`, `outbox.ts.senderProblem` or another sender check
  matching only the connection ID while its current address differs from the
  Draft's frozen From address. Keep the displayed selection consistent with the
  frozen identity, require explicit reselection after a rename, and revalidate
  after awaited claim/storage work immediately before provider handoff. Otherwise
  the composer shows one sender while immutable MIME names another, or a rename
  during those waits bypasses admission's guard. Exercise casing equivalence,
  queued and held-claim/handoff renames, and visible reselection in both hosts;
  do not rewrite an admitted message or add a deferred alias system.

- `outbox.ts.send` or another editor-owned write pinning a Draft identifier before
  awaited asset verification or earlier saves. Resolve the live editor target at
  the serialized write and on each CAS retry while preserving Send's frozen
  content. Product Sync can rebind the editor to a conflict copy during that
  await; a mismatched target and expected identifier otherwise deletes another
  writer's version and admits it alongside the first editor's rendered message.
  Hold a native asset read, trigger a real editor rebind, and verify admission,
  the other writer's retained Draft and reopened storage.
  Compare the admitted Draft against the content used to build the message,
  allowing only the live binding's identifier and conflict-copy metadata to
  follow a rebind. A callback returning newly edited content is not evidence
  that the earlier rendered message matches; refuse the changed Draft rather
  than removing it with an older message. Exercise a same-identifier edit during
  verification as well as a content-preserving conflict-copy rebind.
- `outgoing-message.ts` allowing non-ASCII/control text into native-bound MIME
  segments. Names, subjects and filenames need their existing encodings; raw
  sender/recipient addresses must be refused before Outbox admission, and invalid
  received reply identifiers must be omitted without dropping valid threading.
  Trace every literal header and MIME parameter, including asset identifiers and
  boundaries. Native Gmail accepts ASCII only, so its `unavailable` rejection
  otherwise becomes an endlessly retried offline message rather than useful
  composer feedback. Verify both refusal and ASCII output with Unicode content.
- `assistance.ts.captureDraftText` or a host recomputing refusal guidance from
  raw text instead of the input builder's actual refusal cause. Encoded authored
  text and request framing can exhaust the reply budget despite fitting the raw
  cap; redaction or cut-word removal can instead leave no usable quoted context.
  Carry the builder's diagnosis to both panels, or a refused reply shows generic
  failure for encoded overflow or asks to shorten even an empty authored body.

- `assistance.ts` input builders or `UnwiredAssistance` model prompts using flat
  labelled concatenation instead of a typed JSON request with an explicit
  operation and distinct fields for each admitted context source,
  as required by ADR 0052. Quoted labels or field names must remain escaped data,
  never authored intent or framing. Measure the complete encoded payload against
  the input bound, preserve full admitted authored text, surrogate-safe cuts,
  cut-word address removal and omission disclosure, and keep fixed native
  instructions aligned with the fields. Otherwise adversarial correspondence
  can impersonate the person's reply or escaping can exceed the model budget.

- `assistance.ts.canRewrite` or another shared document helper called during
  host rendering projecting the whole body for an existence check or to derive
  a value the caller already holds for that body revision. Trace its render
  callers and `selectedText`'s `bounds`/`covered` work: a capped text result does
  not bound earlier document-wide traversal or allocation. A collapsed-caret
  Rewrite existence check must stop at the first visible non-image authored span;
  reuse the caller's existing projection when a check needs a document length.
  Otherwise every keystroke repeats whole-body allocation and can stall the
  shared JavaScript runtime for large Drafts. Preserve selected-range eligibility
  and capture-time size/image refusal. Keep event-time callers tied to their
  latest authored body rather than a previous render's projection.

- `assistance.ts.replyInput` or `quotedInput` excluding recipient address fields
  while admitting raw addresses embedded in To/Cc display names, quoted
  attribution lines or other admitted source-message text. Check the complete
  model input, not only its selected fields; otherwise Response Assistance
  processes identities its context contract excludes. Keep traversal and string
  work bounded before filtering, and preserve surrogate-safe cuts even when
  redaction shortens a prefix below its final output bound.
  Charge the cumulative raw recipient-name prefix before redaction; a
  post-redaction length cap can scan the entire recipient list when addresses
  consume no output, multiplying synchronous work beyond the admitted prefix.
  Independently bound recipient entries, including missing or empty names: a
  name-character budget alone cannot stop an address-only list. Trace
  `captureDraftText` too; spreading whole To/Cc arrays before truncation leaves
  collection and allocation unbounded even when `replyInput` stops early.
  A cut can omit the "@" while retaining an address fragment. Drop the entire
  cut whitespace token even when preceding punctuation or text makes it longer
  than an address local part, and bound before trimming leading whitespace;
  otherwise a length heuristic or hidden cutoff admits the fragment.

- `readable-text.ts.paragraphBuilder` or another readable-content filter dropping
  an admitted image occurrence because its alt text is empty or whitespace-only.
  Preserve non-text metadata through span merging, trimming and paragraph
  admission, then trace `responses.ts.forwardedBody` through Draft-owned assets
  and reopened storage. Otherwise Forward silently loses an inline image or its
  position despite having copied its bytes; include image-only paragraphs and
  repeated occurrences in the public forward journey.
- `drafts.ts.withSender` or another reversible selection destructively removing
  mailbox-scoped response metadata. Keep the receiving connection with its Gmail
  thread and derive eligibility from the selected sender through `threadOf`;
  switching away and back must restore that thread while retaining RFC headers.
  `responses.ts.replied` must capture that owner from the initiating source,
  including a sender change by another editor during the first save, rather than
  assign the receiving thread to the Draft's later sender. Otherwise a reversible
  edit loses threading or exposes one mailbox's thread as belonging to another.

- `translation.ts.draftTranslationInput` admitting a selected U+FFFC from an inline
  image into text translation. `semantic-document.ts.replaceSelection` cannot
  reconstruct image metadata from translated text, so accepting the result drops
  the selected image reference. Refuse image-containing selections before native
  inference, explain the refusal in both hosts, and cover text ranges before and
  after images through acceptance, Undo/Redo and reopened Draft storage.

- `composer-navigation.ts.create` keeping an unopened empty Draft after its
  preparation refuses. Route cleanup through `drafts.abandon`, retaining a Draft
  already selected or given content by another editor. Test the real coordinator
  and Draft store together through snapshots and reopened storage; otherwise a
  refused received-attachment action leaves hidden empty Drafts, while unconditional
  cleanup can discard an active editor's work.

- `drafts.ts.attach` or another store action returning a durable-save result to a
  caller that needs to know whether its requested state was retained in memory.
  Trace `composer-navigation.ts.create`/`attachReceived` and the refused-save
  snapshot separately from persistence: retained work must remain visible and
  recoverable even when saving is locked or unavailable. Otherwise the caller
  leaves a hidden Draft/import behind and repeated commands create duplicates
  that become durable on a later save. Keep owner and removal fences; do not
  reinterpret a durability-dependent action such as Close as successful.

- `drafts.ts.importAsset` assuming a rejected native import wrote nothing. Trace
  rejection after ciphertext replacement, file synchronization or the final
  protected-data check; discard unadopted bytes before settling the failed asset,
  including cancelled or stale-owner attempts. Preserve committed/history-held
  assets and keyless cleanup while locked. Otherwise `ImportedAssets` protects
  failed writes until relaunch and exhausts the non-evicting Outgoing Content Store.
- `drafts.ts.download` or another asynchronous Draft asset transfer storing bytes
  after a document commit already dropped their last reference. Recheck the owning
  account's live Draft and history-held keep list after verified completion, reclaim
  unkept bytes and report a missing asset. Exercise Discard while the transfer is
  held, with no later save, while preserving bytes another Draft or Undo still keeps;
  distinguish a stale read's generation from current retention after same-account
  re-entry, so earlier-session cleanup cannot delete a reopened Draft's verified bytes;
  otherwise late writes evade commit-time cleanup and consume the non-evicting
  Outgoing Content Store until an unrelated save or relaunch.
- `drafts.ts.pick` admitting every native picker result, or both hosts passing
  unbounded paste/drop collections to `prepareFiles`. Apply the documented
  per-intake limit before preparing assets or starting imports, and return unused
  picker-owned copies through `discardPickedDraftFiles`, preserving account and
  composer-lifetime fences. Otherwise a large selection amplifies copied bytes,
  queued work and native composer rows despite each file satisfying its byte limit.
- `translation.ts.readerText` or another bounded input builder flattening a whole
  readable body or eagerly spreading a paragraph's spans before applying its
  character cap. Stop traversal and intermediate allocation inside paragraphs as
  well as between them, retaining the omission and surrogate-pair disclosure;
  otherwise opening an ordinary long message stalls both host runtimes even
  before translation is requested.

- `translation.ts.draftReplacement` or a composer applying the trimmed preview
  directly through `semantic-document.ts.replaceSelection`, losing the captured
  selection's leading or trailing whitespace. Preserve that boundary whitespace
  around the translated text; preview normalization must not join neighbouring
  words or remove selected boundary line breaks. Check both hosts' accepted Draft
  edit, including a selection ending in a space before an unselected word.

- `semantic-document.ts.replaceSelection` assigning all translated lines the first
  selected block's kind. Preserve corresponding mixed list/heading/quote kinds
  when line breaks remain, and preserve a partially selected final block's kind
  with its unselected suffix. Check mixed blocks, not just homogeneous bullets;
  otherwise accepted translation changes surrounding semantic formatting.

- `createFreshness.wake` allowing registration verification to auto-load newly
  revealed connections before its route is rechecked. Trace `Registration.refreshInbox`
  publications and `createMailboxes` subscriptions, not just the selected load callback.
  Scoped verification must update ownership and invalidate removed Inboxes without
  dispatching unrelated provider reads; ordinary foreground and interactive loading
  must remain usable. Do not coalesce differently scoped restores or suppress other
  operations across an awaited global flag. Otherwise an ignored revoked wake still
  synchronizes another mailbox. Cover membership revealed during verification, not
  only connections already open before it.

- `semantic-document.ts` expanding every block into per-code-unit editor objects
  on each keystroke, rebuilding unaffected blocks, or retaining expanded arrays
  for every history-held Block in an identity cache. Check typing, formatting,
  Undo/Redo and a long single paragraph across the full `record` history bound.
  Measure peak and retained memory for successive changed-block strings across
  that history and independent composers; sharing only untouched blocks does
  not bound the retained cost of repeatedly editing one large block.
  Preserve immutable untouched blocks and keep retained representations compact;
  weak keys do not release expansions while history still owns those blocks.
  Otherwise ordinary long Draft editing stalls the shared JavaScript runtime or
  multiplies retained memory until the host can be terminated.

- `drafts.ts.recipientSummary` flattening To, Cc and Bcc into one To-prefixed
  list or omitting populated roles within its bounded prefix. Preserve each emitted role and its recipient order,
  use names with address fallback, and return No recipients only when all three
  lists are empty; otherwise a Bcc-only or mixed Draft misrepresents its addressing.
- Shared copy builders, including `drafts.ts.recipientSummary` and
  `registration.ts.privateSyncCopy`, joining translated labels, descriptions or
  notices with fixed spaces or punctuation. Use a complete catalog template with
  named interpolation; otherwise translations cannot control order and separators
  in visible or accessible messages. Keep message content as interpolation data.

- `drafts.ts.recipientSummary` or `semantic-document.ts.clip/previewOf` joining
  complete metadata or bodies before shortening a list-row preview. Bound both
  traversal and intermediate strings, including one huge name/address/span and
  many small recipients or empty blocks; stop once the prefix is complete.
  Preserve short-input role order, separators, whitespace and surrogate pairs,
  and inspect every field and accessible label in `draftSummary` and both host
  consumers. Otherwise an admitted large Draft stalls the shared runtime before
  native one-line truncation applies.
- `drafts.ts.isEmptyDraft` flattening or trimming the complete semantic body to
  decide Close, Discard or abandonment. Test whitespace directly in spans and
  stop at the first non-whitespace character while preserving subject, recipient
  and unfinished-entry semantics; block separators are whitespace. Otherwise
  routine navigation duplicates a large body in memory and blocks the host.

- `semantic-document.ts.marksAt` reporting collapsed-caret marks that disagree
  with `applyText`/`splice` insertion inheritance. Without an explicit typing
  override, both hosts' toolbar visual/accessibility selection and inserted
  characters must agree; their formatting callbacks must toggle that same state.
  Check block starts, empty blocks, positions inside and after list markers,
  mixed-mark boundaries and block ends, retaining an explicit empty override.
  Otherwise formatting is announced as off while typing applies it, and pressing
  the control enables the mark instead of disabling it.

- `createDrafts.create` returning an identifier after its starting Product Account
  generation was invalidated. Fence the result as well as state publication,
  including sign-out/re-entry into the same account; hosts route from that result,
  so a stale successful native completion otherwise opens an absent Draft.

- `createDrafts.create` accepting a sender captured before the open composer
  finishes without rechecking its current connection ID, address and sending
  eligibility. Capture the request's Product Account generation before awaiting
  that finish and revalidate afterward, including a ready or still-loading
  replacement account with the same Gmail connection/address and sign-out/re-entry
  into the same account. Gmail connection IDs do not distinguish Product Accounts.
  Otherwise stale New Message intent creates a Draft from an unavailable sender
  or in a replacement account; fence store mutation as well as the returned ID.

- `createDrafts` replacing a whole stale Draft or storage document without comparing
  the editor's prior content and the durable base. Check simultaneous Mac windows,
  latest-only Drafts, edit-versus-deletion conflicts and owner-checked CAS recovery;
  retain conflicting authored versions as visible copies. Otherwise an ordinary
  autosave silently erases another completed edit or an independently created Draft.
- `createDrafts.save` or another successful recovery action making retained edits
  durable without requesting downstream synchronization abandoned by a failed
  automatic pass. Exercise the debounced pass failing while storage is locked or
  unavailable, then retry without another edit or activation and verify remote
  content. Otherwise Save Drafts reports success but the edits remain device-local
  until an unrelated trigger; failed or stale-owner saves must not publish them.
- `createDrafts.update` forking an editor payload that is unchanged from its
  supplied `previous` merely because another editor or storage writer moved on.
  Leave that list unchanged while still flushing prior dirty work; otherwise
  Close or a repeated native callback materializes stale content as a conflict.
  Compare the immediate authored baseline, including ID, unfinished recipients
  and `conflict` (ignore only edit time), so rebinds, recipient completion,
  discard-failure restore and Undo/Redo returning to older content still save.
- `rebaseDrafts` scanning each complete snapshot again for every Draft identifier.
  Index each snapshot once while keeping the same identifier/content semantics;
  otherwise a large admitted Draft document makes conflict recovery quadratic
  and blocks the shared JavaScript runtime during saving.
- `drafts.ts.conflictCopy` or `copyId` repeatedly suffixing derived identifiers beyond
  a native/transport boundary's length limit. Exercise nested copies through both
  local stale edits and synchronization; keep identifiers bounded without changing
  an existing Draft's identity. Any shortened base must also be used by
  `movesToSyncedCopies`, preserving exact accepted/surviving-content checks and
  existing movements. Require a unique removed source and refuse ambiguous association;
  cover continued editing, Discard and relaunch after shortening, and retained recovery
  of identical-content siblings. Otherwise deep conflict chains cannot synchronize,
  or their editors keep targeting a removed identity despite converged Draft lists.
- `createDrafts.adopt` preserving deletion in only one publication order of an edit-versus-Discard
  race. Check local deletion against a remote edit already published as well as
  a local edit against a published tombstone: the original identity must stay
  removed and the exact authored edit must survive as a conflict copy. Follow
  the editing device's open editor to its preserved copy even when another
  device created it; an identifier prefix without matching authored content
  cannot establish that binding. Exercise continued editing, Discard and relaunch
  through the public stores, including interrupted copy publication before its
  tombstone: compare the actual surviving merged target, which can have newer
  local edits, rather than its last remote record. Otherwise a merge can undo the deletion, lose the edit or
  leave the editor targeting the discarded identity despite converged lists.
- `rebaseDrafts` converging identical authored content by retaining a stale
  writer's earlier `updatedAt`. `sameContent` deliberately ignores edit time;
  preserve the later timestamp when collapsing equivalent versions, while
  retaining the selected content and identity. Check reversed edit/save order
  through two stores and reopening, with another Draft edited between them;
  otherwise CAS recovery moves the Draft backward in `draftsOf`'s newest-first
  list despite preserving its content. Conflict copies keep their own version's
  edit time rather than borrowing a different version's timestamp.
- `createDrafts.update` deciding a fork against a different snapshot from the one
  it mutates, or `rebaseDrafts`/`deleted` moving the pending authored version without
  notifying its editor. Keep the newer stored version's ID and move the stale
  payload; notify after the copy enters the snapshot and before subscribers can
  unmount its editor. Keep the binding through saving and Retry, including durable
  completion; Product Sync `adopt` also moves editors through `rebindEditors`.
  Clear it only on editor release or account invalidation. Two storage writers can
  choose the same free local copy ID; preserve both versions and follow any second
  rename, or Discard deletes the other writer's copy despite preserving its content.
- `createDrafts.editors` retaining only one editor callback for a saved or unsaved
  Draft ID, or leaving one callback bound to several IDs after a synchronous fork.
  Identical-content edits can share the same version; retain and rekey
  every bound editor through storage recovery, remove a stable callback from its
  prior version when it changes targets, and merge bindings when copies collide.
  Recheck membership before each notification: an earlier callback can rebind a
  later editor or invalidate the account during fanout. Keep bindings through
  failed saving, Retry and durable completion, until release or account invalidation.
  Otherwise an editor can remain on, or return to, another writer's Draft and
  subsequently edit or discard that writer's content. Check host callback identity
  and unmount behavior before claiming one callback represents one live editor.
  Release a closed editor's stable callback from every binding without
  dropping its dirty Draft or another live editor's binding. A refused save can
  otherwise retain its entire history and notify dead route/window owners on
  later recovery. A pending Close or Discard still owns identity tracking until
  its target resolution and any failed-discard restoration finish; releasing
  that binding early can report successful Discard while saving its own copy.
- `createDrafts.discard` publishing removal before the native commit succeeds.
  A failed deletion must leave the Draft visible and retryable rather than
  unmounting its editor and reporting completion while it can return after relaunch.
  Automatic empty-Draft disposal must check the current content under the save
  semaphore; an untouched stale composer must not delete another window's work.
  Resolve an editor-owned deletion target under that semaphore after flushing
  earlier saves: a queued save may rebind the editor to a conflict copy. Check
  both explicit Discard and empty Close; capturing an identity when the command
  is requested can delete the other writer's original and leave the intended
  copy behind.
  A clean stale deletion still needs bounded CAS recovery even when no autosave
  is dirty. Re-resolve its target and repeat the empty-only content check after
  rebasing, then settle `save` for preserved content as well as deleted content.
  Otherwise Try again repeats the stale revision, a moved target deletes the
  other writer's copy, or successful empty-only recovery stays at Saving.
  Explicit stale Discard must compare every attempt's target content with the
  discarding editor's accepted version, including the first attempt: another
  window using the same store publishes edits without a CAS conflict. Preserve
  a changed same-ID target while still deleting the editor's own rebound copy;
  otherwise Discard deletes another writer's completed edit even when retry
  checks are correct. Resolve identity and conflict metadata after earlier saves
  without substituting native text accepted while Discard suppresses autosave.

- `composer-navigation.ts.create` applying a late creation result after a later
  accepted destination, or treating every navigation as abandonment. Track only
  successful leaves within the owning Inbox/window, retain a newly selected
  Draft, and remove an abandoned Draft only while it remains empty, including
  after CAS recovery. Refused, rejected, overlapping leaves and same-Draft
  reveal must not cancel creation. Otherwise a slow New Message overrides the
  chosen destination, removes its selected composer, or deletes another editor's
  completed content. Keep this coordination shared rather than duplicating it
  in each host's `DraftList.compose`.
  Record empty abandonment as a dirty edit even when creation or cleanup saving
  is refused: `createDrafts.abandon` must remove it from memory and retain that
  deletion for the next edit, Save Drafts or Retry. Reusing Discard's leading
  flush loses this intent when storage stays locked, so a later successful save
  persists the abandoned blank Draft. Keep explicit Discard visible and retryable
  until durable completion. Preserve another writer's authored content during
  abandonment CAS recovery and keep nonempty late edits through `known` and
  editor rebinding; empty late events must not resurrect the removed identity.
- `createDrafts.update` silently dropping authored content after the original ID
  has been durably deleted, including after `discard({ onlyIfEmpty: true })`.
  Preserve a same-owner nonempty late edit as a conflict copy and notify its
  editor; ignore an empty late edit without dirtying an unchanged list. The
  unchanged-list path in `change` must still flush prior dirty work and resolve
  only once saving settles. Do not treat every missing ID as an owned deletion:
  fence eligible identities to the current Product Account and clear that fence
  on invalidation, or a previous editor's payload can enter another account.

- `createGmailInbox` widening reader membership to online search results while
  attachment download or presentation still requires listed Inbox membership.
  Trace `readable`, `downloadAttachment` and `presentAttachment` together so
  off-Inbox results cannot expose inert Download/Open/Share controls. Search's
  `found` membership must also preserve `settle`'s downloaded-file cleanup when
  a previously listed message leaves the Inbox, without discarding an already
  off-Inbox reader's files on every synchronization; otherwise plaintext file
  ownership silently outlives its documented removal boundary.
- `message-body.ts.safeFilename` shortening a name without its actual final suffix
  while retaining dots that can expose an earlier suffix as the saved extension.
  Preserve the final suffix within both the character and UTF-8 byte bounds, or
  use a dot-free neutral shortened name; trace the displayed descriptor through
  native saving. Otherwise an untrusted attachment can appear to be a different
  file type after truncation, including when only the byte bound is exceeded.
- `message-body.ts.safeFilename` normalizing, transforming or expanding a whole
  sender-controlled name before bounding its input. The Gmail response cap still
  permits huge strings; code-point arrays can exhaust the shared host runtime before
  the output bound applies. Bound work before those operations and preserve suffix
  provenance when discarding the middle: cleaned-away tail padding must not turn a
  retained head dot into the saved extension, even below the output bounds. Exercise
  both surrogate cuts with characters that survive final truncation, and retain
  ordinary Unicode normalization for names within the input bound.
- `message-body.ts.attachmentLeaves` identifying attached messages only through
  the consensus media type. Any Gmail `mimeType` or Content-Type header token
  declaring `message/rfc822` must exclude the part and its descendants, even when
  other declarations conflict. Container traversal must compare Gmail's type with
  every Content-Type header token; header-first `mimeType()` consensus alone misses
  disagreement with Gmail, even with only one header. Keep containers with empty
  or contradictory declarations opaque during both descriptor listing and download revalidation;
  accept case differences, header parameters and a sole non-empty type source.
  Ordinary non-message leaves may retain the neutral file type. Otherwise ambiguous metadata exposes an attached
  message's contents as downloadable files of the outer message.
- `createGmailInbox.prepareReaders` replacing attachment descriptors while retaining
  download state by message ID and positional locator alone. Reconcile derived
  state against the complete descriptor (locator, name, MIME type and size),
  retain unchanged files, and remove ownership before aborting changed or removed
  downloads. Trace `downloadAttachment`'s late-save fence and `presentAttachment`
  after refresh; otherwise a replacement at the same position appears downloaded
  and Open/Share serves the previous file, or a cancelled save restores stale bytes.
- `mailboxes.ts.folded` implementing case-insensitive sender/subject search with
  lowercasing alone or ordering normalization, accent removal and case mapping so equivalent
  text gets different search keys. Check sharp S in both cases, dotted/dotless I,
  compatibility letters exposed by normalization, and sigma in partial words;
  apply the same mapping to queries and metadata. Otherwise saved mail disappears
  from offline search for ordinary case or compatibility variants. Keep this
  user-facing text matching separate from protocol identifiers and CSS keywords.

- `createGmailInbox.save` returning early when native foreground verification has made an enabled Inbox cache-only, without removing its captured unsaved intents and publishing disabled organizing with settled Saving state. Trace `organize`, queued `load` follow-up and native availability/generation gates: no cache-only commit or provider dispatch is allowed, durable pending actions must remain, and discarded unsaved intent needs a visible, announced outcome outside the reader. Report the size of a discarded same-mailbox batch rather than naming only its last request, and preserve that outcome when a subsequent serialized save finds no queued intent. Keep outcome message snapshots scoped to the returned mailbox and initiating ownership epoch; otherwise an action stays saving indefinitely, silently disappears after a removal closes the reader, or exposes another mailbox's message. Do not label a saved-cache rollback as authoritative Gmail reconciliation.
- `createGmailInbox.organize` accepting a message whose Gmail labels are still unknown during legacy-cache relisting, or `quickActions` and either host's `MessageActions` presenting label, move or other organizing controls for that snapshot. Trace intake, retained handlers and `OrganizeNotice` snapshots through queueing and Undo; treating absent labels as an empty set lets an inverse remove pre-existing Gmail memberships. Check predecessor-produced pending snapshots too: `organized` must not turn fallback memberships into a known baseline while replay is unsettled. Keep known-label cached messages usable during ordinary backfill and preserve previously accepted durable intent.
- `createGmailInbox.dispatch` receiving a permanent provider refusal without durably retaining that outcome before its follow-up `readLabels`. An interrupted read or relaunch must make `reconcile` settle provider-derived state and announce rejection without another dispatch, even after Retry or an exhausted attempt budget. Trace `commitOver`/`rebased` so concurrent intake survives both saving the refusal and removing its head; if a refusal-save rebase removes the refused ID, `settleRefusal` must leave the new head untouched rather than read the old message and pop the next intent. Otherwise known-invalid writes repeat, consume attempts and delay later intent, or another message's intent is silently lost.
- `createGmailInbox.settleRefusal` restoring a message-bearing notice after asynchronous work without rechecking its initiating ownership epoch, or losing rejection feedback when settlement is durable but its reply is interrupted. Guard the notice update after the label read and preserve `forget` clearing it during a pending commit; otherwise a late completion exposes the former owner's message in another mailbox, or a lost reply leaves a false success notice after the refused head is gone.
- `createGmailInbox.organize` suppressing an accepted action's `OrganizeNotice` because `restoreAfter` returns no inverse. Both hosts' `OrganizeStatus` announce from that notice, so read/unread, star/unstar, label/unlabel and restore lose outcome feedback if notice publication is coupled to Undo eligibility. Keep outcome publication independent from the host's removal-only Undo gate.
- `sanitizeHtml.anchor`, `readableText` or `paragraphBuilder` bounding only the
  rich link array while retaining unbounded clickable readable spans. Count
  finalized fallback spans across paragraphs as well as collected visible
  anchors; one anchor can become many native controls on both hosts. Excess
  destinations must become plain text with no marker, href or link semantics,
  preserving HTML-only readable content without a budget exception. Verify
  public `presentation`, hidden/restored anchors and both host consumers at and
  beyond the shared limit; otherwise a compact message exhausts native controls
  or a fallback merely relocates the amplification.
- `sanitizeHtml` counting only literal `br` elements while `hr`, preformatted
  newlines, empty styled boxes or hidden text still separate inspected label
  fragments, including source-less hidden image boxes. Share the break run across containers and retained white-space
  modes; non-rendering format/combining characters and hidden text cannot reset
  it. Normalize empty linked boxes without losing visible descendants or image
  visibility semantics, and verify actual emitted WebKit glyph positions with
  inherited tall line heights, smaller inline break styles and rule box geometry,
  and discard line-height expressions or units whose emitted height cannot be resolved,
  without treating arbitrary sender-font `normal` metrics as the system-font multiplier,
  including borders, padding, margins and shorthand ordering, as well as
  `inspectLink` and ordinary-content controls. Otherwise a displaced suffix
  suppresses a caution for the visible address. A normalized, nearby complete
  label may legitimately have no address-mismatch warning; this is not a full
  viewport visibility classifier or a general document-node budget.

- Opening or selecting a message that changes its unread state. Only the explicit read/unread action persists a change, and it must update every subscribed view.
- A store that reports a connected or ready inbox while mailbox authorization is missing, expired, stale or cancelled, rather than the resumable setup or reconnect state.
- `createGmailInbox` treating a native `mailbox-invalidated` rejection as a terminal storage failure before bounded reopening of the committed cache through the registration gate. A successful same-mailbox foreground restore renews the native generation and must not hide usable cached mail. Reopening must preserve the `forget` publication fence after an ownership change or purge; recovery cannot resurrect the former owner's mail.
- `createGmailInbox.downloadAttachment` mapping a native `mailbox-invalidated`
  rejection from Gmail reading or private saving to an attachment storage failure.
  Same-mailbox foreground verification can renew the generation without `forget`;
  clear only the still-live attempt so the row offers an explicit Download again.
  Preserve owner and exact controller fencing so a late invalidated attempt cannot
  erase its replacement, and do not automatically redownload. Otherwise ordinary
  generation renewal falsely reports device-storage failure or clears newer work.
- Gmail HTTP 403 classification that treats documented usage-limit reasons (`dailyLimitExceeded`, `rateLimitExceeded`, `userRateLimitExceeded`) as missing mailbox authorization. A project quota or user rate limit requires retry presentation with cached mail retained; reauthorization cannot fix it.
- Registration, enrollment or recovery state from one Product Account, device or deployment reused after the identity changes.
- A `mailbox-revoked` rejection recovered as a storage failure claiming data was kept after native purge, or a registration handoff that infers revocation from every bare signed-out restore. The purging result establishes the reason; `deviceRemoved` must retain the explanation across ordinary foreground restores, fence it against accepted account changes and explicit removal, and preserve authoritative deletion notices. Otherwise a queued restore erases the explanation or a stale callback mislabels sign-out/deletion.
- Product Sync account-key material, a provider/device credential or a native database encryption key passed into TypeScript. These stay in the native host. The user-held Recovery Key shown during setup is an explicit presentation field in `RegistrationSnapshotSchema`; keep it transient and out of logs and non-native persistence.

- `createGmailInbox` retaining ready mail or synchronization checkpoints in memory after
  its Product Account, provider subject or address changes, or after `canOpenInbox`
  becomes false. Invalidate the snapshot immediately and fence late publications;
  address-only rendering checks can expose a previous account's mail.

#### Tests in the same change

Apply `docs/agents/testing.md`'s admission and proportionate-verification policy: existing meaningful coverage may suffice; document unavailable automation or protected/native evidence with its required follow-up. The cases below identify missing evidence for a named risk, not a requirement to add a test for every edit.

- New or changed store behavior with no test through the store's public interface in `packages/mail-core/test`, covering the failure and recovery path the change introduces. State it as a finding only after reading the existing tests.

#### Leave to tooling

Namespace-import style, `JSON.parse`, `typeof … === 'object'` guards, untagged error classes, and console, time, randomness, `fetch`, timers and `process.env` inside Effect code are lint errors (`scripts/oxlint-effect-policy.ts`). Unused exports and complexity belong to Fallow. Formatting belongs to oxfmt.

#### Rich-body admission and speculative reads

- `html-sanitizer.ts.parseDeclarations` deduplicating before resolving validity
  and importance, or confusing source validity with output retention. Invalid
  important values must not suppress valid normal ones; valid unretained values
  must still replace earlier hiding declarations, and equal-priority winners
  keep their source position for shorthand handling. Check measured WebKit
  grammar (including invalid display combinations and opacity exponents/math),
  CSS whitespace and ASCII keyword matching rather than JavaScript whitespace
  or Unicode case folding,
  emitted CSS, inspected labels and CID discovery together; otherwise hidden
  image parts are downloaded or visible mail is lost. Importance across different
  shorthands/longhands follows the explicitly normalized emitted document, not
  an unimplemented full source cascade.
- `sanitizeHtml.reference` deduplicating sender-controlled CID discovery with a
  growing array scan, or collecting unique references beyond the resolution
  attempt bound. Preserve visible order with constant-time membership checks
  and collect only references within `inlineImageLimits.attempts`; keep every
  visible occurrence for repeated-image presentation charges and keep later
  references as placeholders. Otherwise compact image-heavy mail blocks the
  shared JavaScript runtime before request limits apply, or presentation exceeds
  its image budget.
- `html-sanitizer.ts` splitting inline declarations inside quoted strings or
  unmatched component-value blocks, or treating mismatched closing brackets as
  matching ones in `splitDeclarations`. Drop declarations containing broken
  strings and keep matching delimiter types when scanning. Consume complete
  backslash escapes, including hex digits, optional CSS whitespace and string
  newline continuations, before recognizing delimiters. Remove CSS comments before
  splitting and cascade classification, respecting strings, complete escapes and
  unquoted URL/bad-URL tokens at actual identifier-token boundaries, excluding
  URL spellings inside dimensions, hash and at-keyword tokens. Replacement whitespace must not join identifiers
  when a preceding hex escape consumes its first space, or make a CSS math sum
  valid when its source lacked required whitespace. Cover bad-string recovery,
  escaped newlines and split escaped name/value/importance controls in WebKit;
  otherwise hidden CIDs download or visible mail disappears. Decode semantic names,
  supported identifier values and the importance identifier only after lexical
  splitting; escaped whitespace or punctuation must not become trivia or an
  importance delimiter, and escaped digits must not become number tokens.
  Escapes in the importance identifier must not invalidate an otherwise literal
  numeric value. Verify hidden and visible overrides, invalid escaped-number
  controls, safe emitted identifiers and priority before CID discovery; verify the emitted
  WebKit CSS and inspected link text together. Otherwise reserialization can
  swallow an apparent hiding declaration and leave a painted address uninspected.

- `readableText` trimming closing brackets that belong to IPv6 hosts or balanced
  URL paths, or rescanning the whole URL for every trailing punctuation character.
  Preserve required/balanced delimiters, trim unmatched trailing closers and sentence
  punctuation, keep every text character, and count bracket excess once. Otherwise
  system handoff receives an invalid destination or a punctuation-heavy message
  blocks the shared runtime. Exercise the detected destinations through the public
  inbox store as well as the punctuation parser.
- `createGmailInbox.store` protecting only a prefetch selection that has not yet
  started when cached metadata is already interactive, including after `forget`.
  Derive protection from the current ready list and selection reference at admission,
  alongside active speculative selection; otherwise an opened body can evict recent
  offline bodies during delayed synchronization. Preserve ordered native retention
  and refusal under the hard budget.
- `createGmailInbox.store` waiting for an entire synchronization while holding a
  body-load permit, blocking explicit opens or speculative progress behind provider
  listing. Serialize body membership checks and admission against each page's
  durable commit, pruning and ready publication, including action intake, dispatch,
  reconciliation, refusal, label refresh and Retry/Discard commits through `commitOver`
  and `save`, with provider reads outside that permit. Native FIFO custody orders calls
  but does not make pruning and TypeScript membership publication atomic; verify a
  still-visible action whose reconciliation removes a message while a body completes,
  including an interrupted later history read. Otherwise slow synchronization stalls
  reading, or late downloads repopulate removed messages.
- `createGmailInbox.schedulePrefetch` dropping a queued selection for a newer owner
  when the previous owner's speculative lane finishes or fails. Restart queued
  work under the current owner while retaining publication fences and the
  same-owner retry/authentication pause; otherwise a newly opened mailbox silently
  receives no recent-body prefetch until another synchronization.
- MIME preflight in `message-body.ts` that trusts payload `mimeType` over a
  present Content-Type header or ignores Content-Disposition. Contradictory,
  malformed or attachment metadata must not turn speculation into a multipart
  or attachment download. Both metadata and full preflight must validate every
  whole header value, including trailing parameters and legal folding, before
  speculative admission. Preserve the deliberate leading-token leniency of
  explicit reads; malformed common parameters must not hide readable mail.
  Resolve CIDs only within the selected alternative's
  eligible related/mixed scope, never from a discarded alternative. Prune every
  off-path child of an alternative container regardless of its MIME type,
  including mixed/signed subtrees and image leaves; preserve the selected
  alternative's related resources and eligible inline siblings in outer mixed scopes.
- `message-body.ts` treating a present empty or whitespace-only disposition as
  absent. Only a recognized inline token may admit a present disposition; otherwise
  malformed body or CID leaves can be fetched or shown as ordinary content.
- `message-body.ts.headerParameters` or `partText` choosing a charset from a
  longer parameter name, a comment, another quoted value or a malformed value
  prefix. Consume complete named parameters with the admission grammar, preserve
  legal folding and quoted pairs, stop at malformed parameters and use UTF-8 for
  explicit reads when no complete charset was parsed; otherwise displayed and
  cached text becomes mojibake.
- `message-body.ts.contentIdOf` collapsing whitespace or internal comments inside
  an ID to join its fragments. Internal comments, including nested and empty
  comments, must leave an identity separator and remain unresolvable. Normalize
  surrounding comments, whitespace and brackets while leaving internally spaced IDs unresolvable; preserve literal reference
  matching and repeated-header agreement. Otherwise malformed MIME metadata
  authorizes an unintended inline-image download.
- MIME admission in `message-body.ts` inspecting only the first repeated header.
  Every Content-Disposition occurrence must declare inline; Content-Type tokens
  and normalized Content-ID values must agree across all occurrences. Conflicts
  must not authorize speculative body or CID requests. Resolve only image leaves
  and traverse only explicitly recognized multipart containers in both readable-body
  selection and CID scope discovery; a `multipart/*` prefix alone cannot admit
  extension, encrypted or attached-message containers. Preserve nested ordinary
  bodies in supported signed/report containers, but descend only into their first
  child for both readable body selection and CID discovery, even when nested in
  mixed mail. Signature and report-data children cannot supply HTML or inline
  downloads; a readable first child may itself be a container. A contradictory container or an
  image-shaped subtree must not expose attached descendants.
- `sanitizeHtml` deciding renderability from text and CIDs alone while retaining
  blocked-image placeholders. Placeholder-only mail must keep its rich document
  and readable images notice, including after rendering failure.
- `createGmailInbox` abandoning failed best-effort body pruning when later
  synchronization commits nothing, or pruning from a stale metadata revision.
  Retry after successful synchronization, preserve cache-only access, and require
  revision validation inside native pruning's storage transaction; otherwise
  removed mail stays cached or a competing store's still-listed body is deleted.
- `createGmailInbox.retainBodies` omitting the recent working set during budget
  reconciliation. Both page-commit and end-of-sync pruning must derive protection
  from the retained metadata at the synchronization's selection reference, using
  the Effect clock when no reference remains; otherwise an interrupted writer's
  over-budget directory can lose recent bodies that admission protects.
- `gmail-inbox.ts` charging image data once per CID while rendering repeated
  references, retaining reservations after renderer failure or last-reader
  closure, or racing an explicit open with speculative work for the same ID.
  Count independent readers of the same message, including a window joining an
  already-ready body; a message-ID-only reservation must not let each WebView
  decode another uncharged copy. Admit new readers independently without
  replacing an established reader's document: changing its WebView source starts
  another navigation and resets its position. Fence reservation mutations and release
  callbacks by owner generation, so a stale read or old reader cannot erase a
  new owner's reservation for a reused provider ID.
  Count every rendered occurrence and join the existing pipeline; otherwise
  actual presentation exceeds its bounds or downloads a body twice.
- `createGmailInbox.completeImages` or `resolveImages` swallowing rejected Gmail
  authorization through best-effort MIME reload or attachment recovery. Cached
  and newly opened readable text must remain shown while an owner- and
  listing-fenced authentication notice publishes. Quota and server failures
  must retain their retry fallback without asking for authorization. A successful
  load after authorization must retry ready bodies with unresolved images, and
  a last-reader close during that refresh must prevent hidden presentations and
  reservations from being restored; otherwise reading silently stalls or closed
  windows consume the shared image budget.
- `imageTally.request` charging only admitted image bytes. Reserve the declared
  bytes before each allowed request, including malformed or rejected downloads;
  transient failures cannot refund transferred bytes. Keep this per-open transfer
  bound separate from the reservations for displayed occurrences and readers;
  otherwise rejected images bypass the 20 MiB aggregate download limit.
- Applying geometric viewport admission to Inline Images after the 2026-10-06
  ADR 0029 amendment. Explicit opens resolve all visible, sanitized CID
  references within the existing bounds and shared presentation budget;
  speculative prefetch still excludes them. Remote Message Content retains
  its viewport-plus-margin and authorization rules under #763.
- `inspectLink` matching only raw host text or dotted-quad IPv4. Percent-encoded
  internationalized hosts and compact/hexadecimal IPv4 spellings are interpreted
  by the platform, so inspect their decoded signal form while retaining the exact
  original destination for handoff; otherwise required cautions disappear.
- `inspectLink` excluding numeric displayed addresses from host comparison or
  comparing equivalent percent-encoded, compact IPv4 or IPv6 host spellings as
  different sites. Explicit web schemes, bare dotted-quad IPv4 and bracketed IPv6
  labels must participate alongside bare domains, with a non-empty host and
  normalized comparison key, while preserving the exact destination and numeric
  caution. Ordinary versions, times and dates must not become displayed addresses;
  otherwise deceptive labels lose their caution or equivalent addresses gain a
  false mismatch warning.
- `looksLikeAddress` limiting a bare domain's final label to letters and excluding
  punycode (`xn--`) labels. Bare internationalized-domain spellings, including
  case variants and port/path/query/fragment suffixes, must reach `inspectLink`'s
  comparison while ordinary version text remains outside it; otherwise deceptive
  labels targeting another host omit the mismatch caution. Keep exact destinations
  and the independent internationalized-host signal unchanged.
- `forwardsElsewhere` comparing raw redirect host spellings instead of the same
  `comparisonHost` keys used for displayed addresses. Equivalent percent-encoded
  names and IPv4/IPv6 forms must not produce a cross-site caution; genuinely
  different destinations must retain it and exact handoff URLs must remain unchanged.
- `sanitizeHtml` combining admitted CID image descriptions with separately painted
  link text, or omitting descriptions from image-only links and readable fallback.
  Inspect painted text when present: admitted image alt text is not painted and
  must not mask a displayed address. Use admitted descriptions for image-only
  labels; blocked/unresolved placeholder descriptions are painted and count as
  text. Preserve every readable description in the fallback, normalize whitespace
  and respect unreadable contexts. Otherwise mixed-image deceptive links lose
  their caution, or image-only/accessibility descriptions disappear.
- `isTrackingPixel` ignoring admitted nonpixel CSS dimensions or allowing invalid,
  empty or filtered-out declarations to mask HTML dimensions. Rendering and
  classification must use the same retained width/height/min/max values. Validate
  every retained width/height and min/max dimension with the dimension grammar;
  known pixel minima win over pixel sizes and maxima, including a minimum larger
  than the maximum. Minima are lower bounds, not actual intrinsic/auto/percentage
  sizes; a relative or keyword minimum cannot prove a pixel bound. Otherwise
  visible images are removed or expressions WebKit paints as trackers become
  eligible for CID resolution.
- `sanitizeHtml` suppressing readability or inspected link text from declarations
  discarded by `filterStyle`, such as `overflow:hidden`. Classify text using the
  CSS actually emitted, and validate retained offsets against their property
  grammar before treating text as off-canvas. CSS-wide keywords must stand alone;
  margin shorthand allows at most four lengths or auto values, while the retained
  text-indent subset permits one length and no auto. Invalid units, extra tokens
  or mixed CSS-wide keywords must not suppress a painted label. Whole-element or image exclusion may use declared CSS
  only when it also removes that content from the document. Otherwise painted
  deceptive link labels lose their required caution or readable fallback.
- `sanitizeHtml` classifying every negative margin as off-canvas text. Resolve
  physical shorthand sides and longhands in emitted declaration order, including
  repeated declarations and CSS-wide resets. Only offsets whose emitted layout
  moves the text may suppress it; trailing margins, ignored inline vertical margins
  and inner-table margins cannot justify omission. Bidi flow, automatic direction,
  inline-block baselines and image-to-placeholder replacement require matching the
  output or normalizing uncertain offsets there, rather than retaining hidden
  masking text or omitting a painted label. Otherwise destination-mismatch
  inspection can be bypassed.
- `sanitizeHtml` treating inherited illegible font size as an inescapable ancestor
  box, or treating zero line height and maximum dimensions as clipping when
  overflow remains visible. Descendant sizes must restore inspection. Font
  classification must agree with emitted CSS across Dynamic Type, UA defaults,
  cascade rollback and replacement placeholders: do not assume a universal body
  size, viewport geometry or ex/ch metric while retaining that uncertain CSS.
  Tiny text may paint a smear without being legible. Unsupported font-size
  expressions/units must be removed before both rendering and inspection;
  otherwise invisible masking text suppresses the address mismatch caution.
- `sanitizeHtml` using an offset's magnitude alone to omit inspected text.
  Padding or other compensation and unindented wrapped lines can remain painted.
  Normalize large positive and negative leading offsets and negative offsets with an unknown percentage,
  viewport or font-metric basis in the emitted CSS instead of guessing clipping;
  preserve ordinary small hanging indents, trailing LTR margins and ignored
  inner-table margins. Otherwise a visible deceptive label loses its caution.
- `sanitizeHtml` normalizing only horizontal padding/borders or leaving oversized
  table border spacing, line heights or vertical alignment in emitted text styles.
  Reject unresolved sender CSS functions outside quoted strings in `keptDeclaration`;
  preserve plain `rgb`/`rgba` and `hsl`/`hsla` border colors, but reject nested functions.
  Unresolved expressions such as `padding-left:calc(10000px)` with retained
  `white-space:nowrap` can move the suffix beyond the reader; include the wrapping
  form as a negative control, because it can wrap back into view. A color function
  also separates CSS tokens without whitespace: `border-left:rgb(20,30,40)10000px solid`
  must not evade `normalizeSpacing`'s width bound. Preserve ordinary adjacent-color
  borders while rejecting oversized widths. Verify quote/escape handling and native
  glyph positions rather than omitting scroll-accessible suffixes from inspection.
  Check all admitted physical longhands and shorthand ordering; bound oversized
  aligned text-box widths by their containing block while preserving ordinary
  desktop widths. Otherwise off-screen masking text remains in inspected labels
  and suppresses the visible address's mismatch caution. This bounded style policy
  is not a complete viewport visibility model; verify glyph layout in WebKit.
  Normalize oversized heights/minimum heights and bottom margins too; when
  removing CSS sizing, check whether an admitted HTML table-cell height hint
  becomes active again. Preserve ordinary sizes and ignored inner-table margins.
- `sanitizeHtml` dropping an entire `visibility:hidden` subtree before descendants
  can restore retained `visibility:visible` or `initial`. Carry inherited visibility through
  traversal and restore it for siblings; readable text, inspected link labels,
  image descriptions and CID discovery must agree with the emitted CSS. Preserve
  visibility overrides when replacing images with placeholders or emitting
  special elements such as `br` and `hr`. Hidden images outside active links must keep source-less
  declared geometry without references or blocked-image notices; linked hidden
  image boxes cannot displace inspected suffixes. Wholly hidden
  anchors must not reach host link controls. `anchor` must start without visible
  content; neither an empty wrapper nor whitespace activates its link. Admit only
  retained visible text, images or rules, including restored descendants, so
  discarded children cannot create phantom controls or exhaust the link limit.
  Preserve whole-box
  exclusion for `hidden`, `display:none`, zero opacity and effectively collapsed table tracks;
  otherwise visible mail disappears or invisible images are downloaded.
- `sanitizeHtml` collecting CIDs from cells wholly covered by collapsed table
  columns, or placing cells with raw spans or removed elements that differ from
  the emitted layout. Normalize and bound span values consistently, isolate row
  groups and nested tables, and bound cumulative expansion and occupancy scans
  across all tables; otherwise hidden images download, visible mail disappears,
  or compact rowspan-heavy input blocks the shared JavaScript runtime.
- `inspectImage` trusting a signature/header before validating the complete bounded
  PNG/JPEG/GIF/WebP container, frame count and frame/canvas geometry. Truncated or
  inconsistent data must not supply trusted dimensions or bypass decoded-cost
  admission; ordinary type checks cannot establish those binary invariants.
