# Keep Thread Snooze out of provider state

Thread Snooze is a Profile-scoped product presentation rule, not a Provider Mail Action. The client stores an opaque record per Stable Thread Identity through End-to-End Encrypted Product Sync, including the absolute due instant, the message anchor used to detect later arrivals, and the Trusted Device that owns any Return-to-Attention request. Reschedule and cancel changes converge through the same record family and tombstones; a newer message ends the Snooze before its due instant.

The mailbox projection hides an active Snooze from ordinary Inbox while retaining it in Snoozed, All Mail, and Profile-scoped search. It never changes provider folders, roles, labels, flags, archive state, or deletion state. This keeps reversible product organization independent of provider semantics and makes offline restart depend only on encrypted Product Sync plus locally observed metadata.

Return-to-Attention defaults on per Profile but does not bypass interruption policy. Only the current owner device may present it, and Quiet, Profile Lock, OS notification authorization, and lock-screen content policy may suppress it or replace message content with a generic notification.

Cancellation tombstones are intentionally retained without compaction. The current Product Sync transport exposes no causal convergence boundary that can prove every trusted device has observed a tombstone; deleting one earlier could let an offline device resurrect the Snooze. Bounded compaction is postponed until the transport provides that acknowledgement boundary.
