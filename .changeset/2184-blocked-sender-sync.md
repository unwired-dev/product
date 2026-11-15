---
'@private-email/mail-core': minor
---

Synchronize each Mail Profile's Blocked Senders through Private Sync (#2184, part of #655).

- Each Profile's Blocked Senders are one sealed `profile-blocked-senders.` record written by compare-and-set; native code adds `pullBlockedSenders` and `pushBlockedSenders`.
- `createBlockedSenders` takes an optional `NativeBlockedSenderSync` and gains `synchronize`. Devices merge each address's latest block or unblock, so an unblock is kept as a tombstone; move counts and arrival receipts stay on the device.
- The Mac and iPhone/iPad mailbox screens synchronize Blocked Senders when they open and when the app becomes active or goes to the background, and after each block or unblock.
