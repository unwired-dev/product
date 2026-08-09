---
status: accepted
---

# Coordinate private Scheduled Send on trusted devices

A Scheduled Send is a committed, end-to-end encrypted Outbox item rather than a long Undo Send Window, a provider-native timer, or a Draft reminder. Its exact outgoing payload, assets, selected Mailbox Connection, schedule, and idempotency data synchronize through Product Sync and remain readable only by trusted devices. The backend may retain only the Product Account, opaque schedule identity, absolute delivery instant, expected revision, wake and claim state, and device-authorization generation; it deletes that operational record after terminal delivery, cancellation, or Product Account deletion and never receives provider credentials or performs mail delivery.

Delivery is best-effort at or after the selected instant because Apple does not guarantee background execution. Any compatible trusted device with local authorization for the selected Mailbox Connection and a revocable device-bound Scheduled Delivery Authorization may acquire the one revision-bound Scheduled Send Claim. The backend rejects early or stale-revision claims; editing, rescheduling, cancellation, and mode conversion race atomically with pre-handoff claims. An abandoned pre-handoff claim may expire, but provider handoff creates a durable fence that no other device may cross until the result is reconciled, preventing a lease timeout from duplicating an ambiguously accepted SMTP submission. The ordinary Undo Send Window starts after a due item is claimed and before handoff. A send that cannot begin within 24 hours becomes Needs Attention rather than being delivered stale.

Automatic scheduling fails closed until the complete encrypted payload and operational schedule are acknowledged online. Send Reminders remain Draft-bound, may be created offline, and never authorize delivery. Drafts, Send Reminders, Scheduled Sends, rendered payloads, and authored assets share one non-evicting 100 MB device-wide Outgoing Content Store and reuse encrypted chunks during state transitions. This broadens the Draft-only storage boundary in ADR-0012 and ADR-0025, accepting a synchronized claim protocol, minimal timing metadata, and stricter admission in exchange for private multi-device delivery without silently depending on one originating device.

Removing one device authorization preserves a Scheduled Send for other eligible devices. Removing its Mailbox Connection everywhere or deleting the Product Account explicitly warns and cancels affected commitments. No device may silently substitute a different sending connection.
