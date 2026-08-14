# Synchronize Muted Threads as product state

Muted Threads are Profile-scoped Product Sync records keyed by Mailbox Connection and Stable Thread Identity. Their encrypted payload retains one stable provider-message anchor so a device can repair the mute when provider or RFC rethreading changes the current Thread identity. A durable redirect makes writes through an older identity converge on the repaired identity.

Mute and Unmute update local state immediately and retain an encrypted pending mutation while offline. Concurrent changes resolve by logical timestamp and Trusted Device identity. New replies do not change the record. Settings exposes the current Profile's records so every mute remains inspectable and reversible.

Convex receives only an opaque encrypted payload and an opaque identifier digest. Provider Thread identifiers, subjects, and anchor Message identifiers never cross the device boundary in plaintext. Redirect records are durable and additive; repeated rethreading therefore accumulates a bounded record per former Thread identity. This initial design accepts that growth because the records are small and preserve convergence across offline devices; a future cleanup must retain redirects until every Trusted Device can no longer write through the former identity.

Muting is deliberately outside Provider Mail Actions. It does not hide a Thread, alter unread state, or mutate provider labels, folders, flags, or notification settings. Notification delivery checks authoritative Product Sync state before claiming a notification receipt and again after notification authorization, closing the race where another device mutes a Thread during delivery preparation. The reader applies the same state to proactive Calendar and Unsubscribe suggestions.
