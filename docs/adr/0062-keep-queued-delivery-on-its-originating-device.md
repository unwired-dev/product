---
status: accepted
---

# Keep queued delivery on its originating device

## Device-credential claim amendment — 2026-10-22

For [#983](https://github.com/unwired-dev/product/issues/983), the product owner
authorized the content-free delivery claim using the Trusted Device Credential
alone, without Product Sign-In. Sign in with Apple cannot silently renew a
Product Sign-In after relaunch; requiring it for every claim strands otherwise
authorized queued mail. This exception applies only to `draftDelivery:claim`.
Draft synchronization and other account operations retain their own sign-in
requirements. The [Outbox guide](../outbox.md#delivery-rules) owns the observable
contract.

The mutation must verify a live, account-owned Trusted Device with a stored
credential digest and a matching valid credential. Legacy credential-free
fallback, Pending Devices, foreign devices and retained revocation targets grant
no claim authority. Resolve the stored Product Account and check deletion using
its canonical identity. Device verification, deletion checks and claim insertion
remain in one atomic mutation. The caller's account or device identifier alone
is never proof.

Native code retains the account-owner and existing-key checks, credential/key
custody and revoked/deleted-account purge handling. A successful claim does not
replace fresh device verification before provider handoff. Claim identifiers
remain opaque and fixed-length. The first claimant retains ownership, repeating
its claim after a lost reply is idempotent, and claims are deleted with the
Product Account. An unanswered claim grants no submission permission, and
an uncertain provider handoff is never automatically resubmitted. This decision
adds no cross-device takeover or alternate send path and does not qualify real
provider delivery.

## Launch scope amendment — 2026-10-11

The power-user Apple launch extends these delivery protections and required
content-free atomic Convex send admission to every launch provider. Gmail-specific
wording below records the original provider scope; originating-device ownership
and uncertain-outcome protections remain unchanged. See
[ADR 0069](0069-expand-the-apple-launch-to-power-user-mail.md).

The replacement synchronizes rich-text Drafts and their assets through End-to-End
Encrypted Product Sync, preserving conflicting edits instead of silently
overwriting them. When a person presses Send, the originating device owns the
queued delivery. Another device does not automatically take over that Outbox
message. This keeps cross-device drafting while avoiding a distributed delivery
handoff protocol in the first release.

Use a default 10-second Undo Send window before provider handoff. Keep the
uncertain-outcome protection in
[ADR 0016](0016-durable-outbox-delivery-attempts.md): an ambiguous result must not
cause an automatic resubmission while delivery is unknown. A delay after pressing
Send is not a promise that the provider can recall an already submitted message.

Closing the last Mac window keeps the application running and eligible to process
its queue. Explicit Quit stops synchronization and queued delivery until reopening.
There is no independently running helper in the first release. iPhone and iPad
execution remains best effort under
[ADR 0013](0013-best-effort-device-side-mail-freshness.md). Queued delivery therefore
depends on the originating device being able to execute with valid authorization.

Treat Convex as a required service for send admission. Before Gmail submission,
the originating device obtains an atomic, content-free ownership claim for the
synchronized Draft so two devices cannot independently submit it. Offline
composing and queueing remain available; a successful claim is required before
provider handoff. A failed or interrupted claim uses the ordinary pending/error
path and cannot be treated as permission to submit.

Do not build a separate Convex-outage mode, alternate coordinator, or
uncoordinated sending path for the first release. This keeps the required-service
model simple. An expired timer or uncertain claim response never transfers
delivery ownership or overrides the existing uncertain-provider-outcome rule.
