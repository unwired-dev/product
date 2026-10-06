Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to `packages/mail-core`.

`packages/mail-core` holds the shared application logic as Effect programs behind framework-independent stores (`getSnapshot`, `subscribe`, Promise-returning actions). The iOS/iPadOS Hermes bundle and the React Native macOS bundle both compile this source, so a mistake here ships to every host.

#### Dependency direction

- An import of `react`, `react-native`, `expo*`, `convex`, a `node:` built-in or anything under `apps/`. Hosts own views and native adapters; the Mac bundle check rejects the mobile renderer, and a UI import here forces incompatible renderers together.
- A production module that imports from `src/testing/`. Metro substitutes those modules only for a named Mock Mail Session scenario (`scripts/mock-mail-build.cjs`); a static import carries synthetic providers into release bundles.
- A module hosts need that has no subpath in `package.json` `exports`, or a host reaching it through a relative path into `src/`. The exports map is the package's public interface.
- Native capability passed in as a concrete module rather than as an interface the host supplies (as `NativeInboxStorage` is supplied to `createPersistentInbox`). The interface keeps the store testable with real logic and a substituted boundary.

#### Shared runtime compatibility

- Regex extraction in `message-body.ts` or another shared decoder that assumes
  `matchAll` results retain `.groups` after a host's Babel named-group transform.
  Hermes can omit that property while Node tests pass, silently dropping message
  content or link destinations. Read captures portably and validate changed
  parsing in the packaged host when its transform differs from the test runtime.

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
- `getSnapshot` returning a newly built object or array when nothing changed. `useSyncExternalStore` compares by identity and re-renders forever.
- `subscribe` that does not return an unsubscribe removing exactly that listener, or a publish path that skips listeners after a state change.
- A `ManagedRuntime`, fiber, timer or subscription created without an owner that disposes it; a `ManagedRuntime` created for a Layer with no dependencies or resources.
- A retry or poll without a bound, or built from `setTimeout`/recursion rather than `Schedule`.

#### Services

- A `Context.Service` introduced where no caller needs a replaceable dependency; a value a closure already owns stays a plain value.
- A service whose dependencies are acquired inside methods rather than once in `make`, whose shape is forced with a type assertion rather than inferred from the returned `as const` object, or that has no static `layer`.
- A service identifier that does not follow `@private-email/<package>/<Name>`; identifiers key the context, and a collision silently resolves the wrong service.

#### Product behavior the stores own

- Opening or selecting a message that changes its unread state. Only the explicit read/unread action persists a change, and it must update every subscribed view.
- A store that reports a connected or ready inbox while mailbox authorization is missing, expired, stale or cancelled, rather than the resumable setup or reconnect state.
- `createGmailInbox` treating a native `mailbox-invalidated` rejection as a terminal storage failure before bounded reopening of the committed cache through the registration gate. A successful same-mailbox foreground restore renews the native generation and must not hide usable cached mail. Reopening must preserve the `forget` publication fence after an ownership change or purge; recovery cannot resurrect the former owner's mail.
- Gmail HTTP 403 classification that treats documented usage-limit reasons (`dailyLimitExceeded`, `rateLimitExceeded`, `userRateLimitExceeded`) as missing mailbox authorization. A project quota or user rate limit requires retry presentation with cached mail retained; reauthorization cannot fix it.
- Registration, enrollment or recovery state from one Product Account, device or deployment reused after the identity changes.
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

- `createGmailInbox.store` waiting for an entire synchronization while holding a
  body-load permit, blocking explicit opens or speculative progress behind provider
  listing. Serialize body membership checks and admission against each page's
  durable commit, pruning and ready publication, with provider reads outside that
  permit; otherwise slow synchronization stalls reading, or late downloads
  repopulate removed messages.
- `createGmailInbox.schedulePrefetch` dropping a queued selection for a newer owner
  when the previous owner's speculative lane finishes or fails. Restart queued
  work under the current owner while retaining publication fences and the
  same-owner retry/authentication pause; otherwise a newly opened mailbox silently
  receives no recent-body prefetch until another synchronization.
- MIME preflight in `message-body.ts` that trusts payload `mimeType` over a
  present Content-Type header or ignores Content-Disposition. Contradictory,
  malformed or attachment metadata must not turn speculation into a multipart
  or attachment download. Resolve CIDs only within the selected alternative's
  eligible related/mixed scope, never from a discarded alternative. Prune every
  off-path child of an alternative container regardless of its MIME type,
  including mixed/signed subtrees and image leaves; preserve the selected
  alternative's related resources and eligible inline siblings in outer mixed scopes.
- `message-body.ts` treating a present empty or whitespace-only disposition as
  absent. Only a recognized inline token may admit a present disposition; otherwise
  malformed body or CID leaves can be fetched or shown as ordinary content.
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
- `sanitizeHtml` omitting visible image descriptions from their enclosing link's
  inspected text. Include descriptions for placeholders and admitted CID images,
  normalize link whitespace and respect unreadable contexts; otherwise image-only
  deceptive links bypass the destination mismatch caution.
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
- `inspectImage` trusting a signature/header before validating the complete bounded
  PNG/JPEG/GIF/WebP container, frame count and frame/canvas geometry. Truncated or
  inconsistent data must not supply trusted dimensions or bypass decoded-cost
  admission; ordinary type checks cannot establish those binary invariants.
