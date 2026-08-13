# Synchronize Muted Threads as product state

Muted Threads are Profile-scoped Product Sync records keyed by Mailbox Connection and Stable Thread Identity. Their encrypted payload retains one stable provider-message anchor so a device can repair the mute when provider or RFC rethreading changes the current Thread identity. A durable redirect makes writes through an older identity converge on the repaired identity.

Mute and Unmute update local state immediately and retain an encrypted pending mutation while offline. Concurrent changes resolve by logical timestamp and Trusted Device identity. New replies do not change the record. Settings exposes the current Profile's records so every mute remains inspectable and reversible.

Muting is deliberately outside Provider Mail Actions. It does not hide a Thread, alter unread state, or mutate provider labels, folders, flags, or notification settings. Notification delivery checks authoritative Product Sync state before claiming a notification receipt and again after notification authorization, closing the race where another device mutes a Thread during delivery preparation. The reader applies the same state to proactive Calendar and Unsubscribe suggestions.
