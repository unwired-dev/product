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
wire schemas shared by the receiver and client. Its Convex-validator counterpart
is a separate entry point. The [ADR 0065 amendment](../adr/0065-scope-effect-adoption.md#declarative-wire-schemas-in-contracts)
permits this dependency without introducing application logic into contracts.

`host.ts` observes native failures without replacing their result. It decodes only
bounded HTTP status and, for Convex replies, the fixed envelope status. Response
text, request paths, account/mailbox locators and arguments never enter reporting.
Ambiguous legacy native `unavailable` rejections are omitted only from operation
reporting because they also represent expected offline conditions. Global
unexpected exception capture is unchanged. The JS projection keeps exact approved messages and positional bundle coordinates;
packaged Hermes may omit named capture-group dictionaries.

## Revocation and deletion

The native consent generation fences saves, callbacks and requests. Bridged enables
carry the observed generation and cannot undo a later withdrawal. Withdrawal
closes collection and cancels enable/capture before waiting for the network. A
separate file marker survives locked-Keychain or interrupted account cleanup;
restart retries withdrawal until acknowledgement. An installation that never opted
in does not send a capability merely to withdraw reporting.

Deletion publishes its pending intent before awaiting withdrawal, so another window
cannot re-enable reporting during that wait. A refused older save clears its queue
without erasing deletion intent. The installation credential survives
account purge. Only verified remote completion permits a later explicit enable,
which rotates the reporting identity.

Receiver mutations authenticate capability digests and serialize consent changes.
A delivery lease precedes each external vendor request; deletion waits for every
lease before checking the vendor. The durable worker polls person deletion status
and verifies the profile's absence only after a completed, verified deletion record.
A hard-killed request with an unsettled lease remains pending for operator review.

## Disconnected native collector

Sentry Cocoa 9.30.2 supplies only a local collector, not a second receiving service.
Its custom `Options.urlSession` blocks every SDK request before a socket, including
close's flush. `beforeSend` extracts the approved projection then returns nil.
Revocation closes the SDK and removes its complete application-owned raw cache
and native projection queue. The production qualification flag defaults false.

The retained #1050 probe establishes the exercised macOS lifecycle feasibility,
not signed-project, mobile, vendor deletion or symbolication qualification. Raw
local crash persistence while opted in is permitted; it never bypasses the safe
outgoing inventory or withdrawal purge.
