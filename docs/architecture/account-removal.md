# Account removal: architecture notes

Reviewer-only companion to [the operational guide](../account-removal.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).

## Identity and backend cleanup

Issue #603 uses the existing durable deletion pipeline with a recently authenticated
HTTP entry point for Google-only accounts. The route checks the validated bearer
identity and a five-minute issue-time bound before calling an internal action.
Initial deletion retains Trusted Device proof. An account opened by Apple requires
Apple's single-use authorization code and client binding, regardless of its original
provider. Revocation finishes before irreversible data deletion; Google mailbox
authorization is never revoked by this operation. These boundaries apply
[ADR 0021](../adr/0021-delete-product-accounts-immediately.md) and
[ADR 0061](../adr/0061-separate-product-identity-from-registration-mailbox-authorization.md).

The Google-only request starts directly in `deleting-data` and schedules its
continuation in the same transaction. Existing requests in that phase have already
passed authorization and fence all ordinary account access. A recent authenticated
identity owning such a request may resume without a surviving Trusted Device row;
bounded cleanup removes those rows before completion. Initial requests and
revocation-pending work still verify the device proof. Linked identities receive
their own identity tombstones before their links are drained.

[ADR 0066](../adr/0066-admit-devices-only-through-authorized-enrollment.md)'s
Pending Device admission and deletion without a Trusted Device remain the accepted
follow-up in #750. This slice does not implement that new enrollment protocol.

## Local interruption and key safety

`SavedRegistration.accountRemoval` records requested removal before remote work.
An unanswered request retains its account locator and data, clears in-memory
authorization on restore, and offers only that removal's retry through the bridge.
It cannot reconnect a potentially unregistered installation. The pending status
crosses the bridge as presentation metadata, without keys or provider credentials.

Definite HTTP refusals (401, 400, unstructured 403 and Apple-required 409) clear
intent only when this attempt created it. They establish that this request did not
start deletion, not that an earlier unanswered request did nothing. A refused
retry preserves pending deletion and reports an uncertain outcome. Structured
revocation and deletion rejections still purge. An Apple-required refusal also
adds Apple to the saved provider list, so the next deletion signs in through Apple
even when this device had not observed the link.

`purge` durably records acknowledgement before attempting dependent Keychain
removals, attempts every known account item, and deletes registration last. A crash
or failed dependent removal therefore leaves a locator and acknowledged cleanup
state that restore processes before provider work. The purge path also owns
revocation and deleted-account rejection, retaining their distinct notices.

Sign-out renews Google silently or Apple interactively, matches the saved identity,
reconciles rotation and retains unconfirmed Recovery Keys. A held confirmed key must
open the current authoritative recovery envelope outside a matching pending epoch.
This preserves the backup and rotation guards in
[ADR 0001](../adr/0001-end-to-end-encrypted-product-sync.md) and
[ADR 0020](../adr/0020-revoke-devices-with-sync-key-rotation.md).

Remote deletion is learned through authenticated account rejection. A Google
restore reconnects; Apple relaunch checks its provider grant and learns deletion
on its next interactive sign-in or authenticated backend operation. No public
account-ID tombstone oracle or retained device credentials are added. Offline or
compromised copies remain outside remote-erasure guarantees. The synthetic Inbox
fixture has no Product Account ownership; the Gmail mailbox cache joins the purge boundary in #604. Future Drafts must
join it too.

## Evidence

[The operational guide](../account-removal.md#deterministic-evidence) records the
suite paths and distinguishes real Keychain/CryptoKit with synthetic backend
boundaries from packaged mock journeys and protected provider qualification.
