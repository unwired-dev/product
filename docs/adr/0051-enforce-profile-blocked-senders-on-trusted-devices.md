---
status: accepted
---

# Enforce profile blocked senders on trusted devices

Blocked Senders are profile-scoped Mail Workflow Preferences represented by exact normalized email addresses. The Apple client synchronizes their last-writer-wins block and unblock mutations through an opaque singleton protected by End-to-End Encrypted Product Sync. The backend sees a stable record identifier and encrypted payload, never readable sender addresses, message identities, or provider mutation requests. A device keeps pending mutations locally so blocking and unblocking remain available offline and converge when Product Sync returns.

Enforcement happens only for messages identified as newly arriving by a Mailbox Connection synchronization. An exact normalized sender match is removed from that synchronization's new-message notification candidates and, when the current trusted device is authorized and the connection supports the recoverable delete action, is enqueued through the existing durable Provider Mail Action boundary to move it to Trash. Device-local receipts prevent the same arrival from being enqueued repeatedly. Existing messages are not scanned retroactively, display names and domains do not match, provider aliases are not inferred, and unblocking does not restore mail already moved to Trash.

This keeps provider credentials and execution on trusted devices, preserves recoverability and Pending Provider Action retry semantics, and makes capability gaps visible in Account Settings. It accepts that a profile can retain a synchronized preference while a connection waits for an authorized capable trusted device to enforce it.
