# Error reporting: architecture notes

Reviewer-only companion to [the telemetry requirements and operations](../telemetry.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
This records issue #1049's implementation; native and live-vendor release
qualification remains blocked by the checks in #1050.

## Ownership and payload boundaries

The approved ownership panel chose one shared `mail-core` Effect store for consent,
projection, bounded queue and deletion policy. Swift owns the separate device-only
Keychain identity and capability, atomic generation/CAS persistence, and collector
lifetime. This follows ADR 0067's native custody boundary. Host views consume the
store; native credentials never cross the bridge.

The `contracts/errorReportingSchema` entry point contains only declarative Effect
wire schemas shared by the receiver and client. A separate type-only entry point
derives its public reporting types from those schemas without runtime imports. The [ADR 0065 amendment](../adr/0065-scope-effect-adoption.md#declarative-wire-schemas-in-contracts)
permits this dependency without introducing application logic into contracts.

`host.ts` observes native failures without replacing their result. It decodes only
bounded HTTP status and, for Convex replies, the fixed envelope status. Response
text, request paths, account/mailbox locators and arguments never enter reporting.
Ambiguous legacy native `unavailable` rejections are omitted only from operation
reporting because they also represent expected offline conditions. Global
unexpected exception capture is unchanged. The JS projection keeps exact approved messages and positional bundle coordinates;
packaged Hermes may omit named capture-group dictionaries.

## Startup

The [startup decision](https://github.com/unwired-dev/product/issues/1049#issuecomment-6256015256)
keeps synchronous native roots and headless startup. The reporting module exports
an initial snapshot on the main queue, using the existing native read without
exposing its credential. Each host's minimal `host.ts` passes the unknown snapshot
to the shared strict bridge/document decoder before `reporting-bootstrap.js`
installs the saved global and ExceptionsManager handlers. The entry imports that
bootstrap before registration side effects, delivery, freshness, routing or windows.

Only a valid available enabled idle snapshot permits startup capture. Missing,
locked, unavailable or malformed state stays off without retaining raw errors.
Native load validates a present nested document before collector startup or any
persistence. Malformed data stops/cancels collection and purges raw cache best
effort, without rewriting consent, generation, pending deletion or the installation
credential. Only absence permits a fresh document; structurally valid expired
reports are pruned separately. Strict shape checks retain supported numeric forms
and present or omitted optional fields while rejecting excess keys and null optionals.
The ordinary asynchronous load still reconciles native state and starts polling;
startup capture retains native generation/CAS and synchronous withdrawal fences.
The bootstrap's own dependencies remain outside its hooks' protection. Real
module-order, bridge/isolation and cold-start delivery qualification remains
required under #1050; substituted entry/store tests do not establish it.

## Capture retries

The shared store keeps a Clock deadline for capture retries. Native-compatible
integer hints span zero through 24 hours; missing, zero or malformed capture
hints use the 30-second polling interval. Native enable and capture transport
rejections also impose that fallback. The enable error path preserves its original
failure and rechecks the consent revision after reading Clock before installing the
deadline. Before the deadline, flush still
prunes, drains validated native reports, bounds and saves the queue, but sends
neither enable nor capture. Acceptance clears the deadline. Consent revision and
native generation changes invalidate it; late replies cannot restore it after
withdrawal. Deletion and revocation do not wait for capture backoff.

## Revocation and deletion

The native consent generation fences saves, callbacks and requests. Bridged enables
carry the observed generation and cannot undo a later withdrawal. Withdrawal
closes collection and cancels enable/capture before waiting for the network. A
separate file marker survives locked-Keychain or interrupted account cleanup.
Account cleanup requires successful native consent persistence or a fresh
wildcard marker write; an older marker is insufficient. If both fail, the
throwing callback stops account-record, session and purge mutations while
collection stays blocked in the current process. Cleanup does not wait for the
receiver; restart retries withdrawal until acknowledgement. An installation that
never opted in does not send a capability for revoke, delete or status. Its deletion
completes locally using durable `everEnabled` authority, without inferring report absence
from an empty queue. An installation that previously opted in retains remote
withdrawal and verified-deletion requirements.

Deletion closes collection and publishes its pending intent synchronously, then
persists the empty document before crossing the withdrawal bridge, refreshing
the decoded native generation after a refused save. Status retries wait for
native withdrawal acknowledgement. Native save atomically disables consent and
advances its generation when deletion first becomes pending, even if already off,
then closes the collector and purges its queues. Pending deletion refuses enables,
fences older saves and gates native startup. Reopen also fences older persisted
enabled state. Withdrawal still runs if saving fails. A purge failure after
persistence cannot erase the pending intent, and refreshes or old
acknowledgements cannot replace it during consent changes. A refused older save
clears its queue without erasing deletion intent. The installation credential
survives account purge. Only verified remote completion permits a later explicit
enable, which rotates the reporting identity.

Receiver mutations authenticate capability digests and serialize consent changes.
A delivery lease precedes each external vendor request; deletion waits for every
lease before checking the vendor. The durable worker polls person deletion status
and verifies the profile's absence only after a completed, verified deletion record.
A hard-killed request with an unsettled lease remains pending for operator review.

## Backend health budget

The existing reporting-state module owns one identity-free durable timestamp. Its
mutation atomically admits and schedules at most one APNs health attempt per hour
across concurrent actions and restarts. Failed attempts consume that interval.
The APNs edge ignores admission failure so diagnostics cannot change delivery or
stale-token cleanup. No account, recipient or installation key enters this state.
The [quota implementation decision](https://github.com/unwired-dev/product/issues/1049#issuecomment-6254596975)
keeps this narrow budget separate from app consent and adds no limiter dependency.

## Disconnected native collector

Sentry Cocoa 9.30.2 supplies only a local collector, not a second receiving service.
Its custom `Options.urlSession` blocks every SDK request before a socket, including
close's flush. `beforeSend` extracts the approved projection then returns nil.
The pinned converter supplies outermost-first wire frames; projection retains
the final 64 admitted frames in that order, including the crash site.
Revocation closes the SDK and removes its complete application-owned raw cache
and native projection queue. The production qualification flag defaults false.

The retained #1050 probe establishes the exercised macOS lifecycle feasibility,
not signed-project, mobile, vendor deletion or symbolication qualification. Raw
local crash persistence while opted in is permitted; it never bypasses the safe
outgoing inventory or withdrawal purge.
