Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to `packages/mail-core`.

`packages/mail-core` holds the shared application logic as Effect programs behind framework-independent stores (`getSnapshot`, `subscribe`, Promise-returning actions). The iOS/iPadOS Hermes bundle and the React Native macOS bundle both compile this source, so a mistake here ships to every host.

#### Dependency direction

- An import of `react`, `react-native`, `expo*`, `convex`, a `node:` built-in or anything under `apps/`. Hosts own views and native adapters; the Mac bundle check rejects the mobile renderer, and a UI import here forces incompatible renderers together.
- A production module that imports from `src/testing/`. Metro substitutes those modules only for a named Mock Mail Session scenario (`scripts/mock-mail-build.cjs`); a static import carries synthetic providers into release bundles.
- A module hosts need that has no subpath in `package.json` `exports`, or a host reaching it through a relative path into `src/`. The exports map is the package's public interface.
- Native capability passed in as a concrete module rather than as an interface the host supplies (as `NativeInboxStorage` is supplied to `createPersistentInbox`). The interface keeps the store testable with real logic and a substituted boundary.

#### Untrusted boundaries fail closed

- A native bridge result, seed, persisted JSON value, HTTP body, token or route parameter used before a `Schema` decode, or narrowed with `as`, a hand-written property check or a truthiness test. The Apple host's checks do not make its results trusted in TypeScript.
- A decode failure that becomes a default, an empty list or a `ready` state. It must map to the boundary's existing tagged error, with the decode error as `cause`, and surface as a non-ready state.
- A schema widened (`Schema.Unknown`, optional field, loose union) to make a fixture or a new native result pass, without the consumer handling the widened case.

#### Errors and diagnostics

- A failure modelled as a thrown `Error`, a string or a boolean where callers need to tell cases apart; use `Schema.TaggedError`, with a foreign error carried as `cause: Schema.Defect()`.
- An expected state (locked storage, cancelled or declined sign-in, enrollment waiting) logged as an error, or an unexpected failure recovered without `Effect.logError`.
- A log, annotation or error message that carries `cause`, `error.message`, `String(error)`, a payload, an email address, a token or an account, device or message identifier. Any field of a host or provider error can hold mail or account data; log only what `rejectionDiagnostic` and `decodeDiagnostic` in `src/diagnostics.ts` produce.
- A new native rejection code handled in a store without being added to `nativeCodes` in `src/diagnostics.ts` (it logs as `unrecognized code` and cannot be diagnosed), or that allow-list widened to pass through arbitrary strings.
- `Effect.catch`/`catchAll`-style recovery that swallows a failure the caller's contract does not permit recovering, or `Effect.orDie` on a failure a user can trigger.

#### Running programs and shared state

- `Effect.run*` anywhere except the single run of a host-facing store method through `runLogged`; in particular inside a service method, a callback passed back into Effect, or a loop.
- A host-facing action whose Promise can reject for an expected state. Hosts call actions as `void store.load()`, so a rejection is an unhandled promise rejection; expected failures become snapshot state.
- Overlapping asynchronous store actions that read, change or publish shared state without the store's `Semaphore`, so they interleave a read-modify-write or a slower earlier call publishes over a newer result. Synchronous `getSnapshot` and listener bookkeeping do not require an Effect run or permit. Use `withPermit` to queue and `withPermitsIfAvailable` only where dropping the overlapping request is the intended behavior.
- `createRegistration.resume` dropping a foreground activation because the account is unlocked or a pending operation holds the semaphore. Queue every activation's native restore after the current operation, preserving unchanged setup feedback while publishing changed verification or locked results; otherwise unlock retries are lost or a running account remains connected after verification becomes unavailable. ADR 0020 requires foreground Trusted Device revalidation; a locked-storage retry must not exempt unlocked accounts, and native reconnect alone does not prove that revocation rejection purges local state.
- `createRegistration.resume` treating each Mac window's report of one application activation as a separate restore. The windows share one store and AppState dispatches listeners synchronously, so coalesce those reports or give the subscription one application-level owner; otherwise native Product Account and Gmail verification repeats per window and prolongs the busy state. Coalescing must end with that dispatch, not with the pending restore, so a later activation after unlock still queues a fresh verification.
- A successful persisted state published before the native operation has durably completed, with no failure path that restores the previous state. Explicit busy/pending presentation states are permitted, as in `createRegistration`.
- A whole-document CAS conflict in `createGmailInbox` that restarts all synchronization for ordinary concurrent intake, discards newly durable intents, or resurrects an action settled by this operation or another store instance. Review `commitOver`/`rebased` against both the prior base and latest saved pending IDs, including dispatch preparation and settlement, reconciliation, labels and blocked-action resolution. Drop previously known IDs absent from the latest document and revalidate the prepared head before dispatch. Retain newly appended intake IDs in FIFO order, bound rebases, and reject another mailbox/owner before any write; repeated benign intake must not exhaust whole-sync retries or duplicate provider actions.
- `getSnapshot` returning a newly built object or array when nothing changed. `useSyncExternalStore` compares by identity and re-renders forever.
- `subscribe` that does not return an unsubscribe removing exactly that listener, or a publish path that skips listeners after a state change.
- A `ManagedRuntime`, fiber, timer or subscription created without an owner that disposes it; a `ManagedRuntime` created for a Layer with no dependencies or resources.
- A retry or poll without a bound, or built from `setTimeout`/recursion rather than `Schedule`.

#### Services

- A `Context.Service` introduced where no caller needs a replaceable dependency; a value a closure already owns stays a plain value.
- A service whose dependencies are acquired inside methods rather than once in `make`, whose shape is forced with a type assertion rather than inferred from the returned `as const` object, or that has no static `layer`.
- A service identifier that does not follow `@private-email/<package>/<Name>`; identifiers key the context, and a collision silently resolves the wrong service.

#### Product behavior the stores own

- `createGmailInbox.organize` accepting a message whose Gmail labels are still unknown during legacy-cache relisting, or `quickActions` and either host's `MessageActions` presenting label, move or other organizing controls for that snapshot. Trace intake, retained handlers and `OrganizeNotice` snapshots through queueing and Undo; treating absent labels as an empty set lets an inverse remove pre-existing Gmail memberships. Check predecessor-produced pending snapshots too: `organized` must not turn fallback memberships into a known baseline while replay is unsettled. Keep known-label cached messages usable during ordinary backfill and preserve previously accepted durable intent.
- `createGmailInbox.dispatch` receiving a permanent provider refusal without durably retaining that outcome before its follow-up `readLabels`. An interrupted read or relaunch must make `reconcile` settle provider-derived state and announce rejection without another dispatch, even after Retry or an exhausted attempt budget. Trace `commitOver`/`rebased` so concurrent intake survives both saving the refusal and removing its head; if a refusal-save rebase removes the refused ID, `settleRefusal` must leave the new head untouched rather than read the old message and pop the next intent. Otherwise known-invalid writes repeat, consume attempts and delay later intent, or another message's intent is silently lost.
- `createGmailInbox.settleRefusal` restoring a message-bearing notice after asynchronous work without rechecking its initiating ownership epoch, or losing rejection feedback when settlement is durable but its reply is interrupted. Guard the notice update after the label read and preserve `forget` clearing it during a pending commit; otherwise a late completion exposes the former owner's message in another mailbox, or a lost reply leaves a false success notice after the refused head is gone.
- `createGmailInbox.organize` suppressing an accepted action's `OrganizeNotice` because `restoreAfter` returns no inverse. Both hosts' `OrganizeStatus` announce from that notice, so read/unread, star/unstar, label/unlabel and restore lose outcome feedback if notice publication is coupled to Undo eligibility. Keep outcome publication independent from the host's removal-only Undo gate.
- Opening or selecting a message that changes its unread state. Only the explicit read/unread action persists a change, and it must update every subscribed view.
- A store that reports a connected or ready inbox while mailbox authorization is missing, expired, stale or cancelled, rather than the resumable setup or reconnect state.
- `createGmailInbox` treating a native `mailbox-invalidated` rejection as a terminal storage failure before bounded reopening of the committed cache through the registration gate. A successful same-mailbox foreground restore renews the native generation and must not hide usable cached mail. Reopening must preserve the `forget` publication fence after an ownership change or purge; recovery cannot resurrect the former owner's mail.
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
