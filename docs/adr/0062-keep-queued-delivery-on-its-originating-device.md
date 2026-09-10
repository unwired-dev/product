---
status: accepted
---

# Keep queued delivery on its originating device

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
