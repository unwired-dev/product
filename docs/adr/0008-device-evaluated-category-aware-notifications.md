# Device-evaluated Category-Aware Notifications

Notification Rules are user-owned encrypted Product Sync data. The Apple client stores the selected category identifiers in one encrypted payload and decrypts them only on trusted devices. Convex stores the opaque payload identifier, ciphertext, nonce, and key version; it cannot read the selected categories or use them to decide which devices receive wakeups.

Authenticated Notification Rule loads and saves refresh an account-scoped, device-only Keychain cache of that opaque encrypted payload. A background wake first attempts Product Sync and may decrypt the cached payload when remote loading fails, including when the stored Product Account identity token has expired. Foreground loads still surface authentication failures, a successful authenticated empty response clears stale cached rules, and no session means the background route remains fenced after sign-out. The cache uses after-first-unlock, this-device-only accessibility so system-granted background work can read it without making the rules portable or plaintext at rest.

A provider-native push signal remains a content-free background wakeup. The receiving device first fetches recent mailbox changes with that **Mailbox Connection**'s device-held authorization and runs local System Categorization. It may schedule a visible local notification only for a newly observed, non-historical message whose resulting Message Category matches a decrypted Notification Rule. The visible notification itself does not include the message subject, sender, category, or body.

Notification Rules are empty by default. If local metadata cannot be read, rules cannot be decrypted, categorization produces Uncategorized State, local notification delivery fails, or the app has no safe background execution time remaining, category-aware processing fails closed.

The Apple client also provides a separate, device-local Generic Notification Fallback. It is disabled by default and scoped to the Product Account on that device. When enabled, the client may replace failed, incomplete, or out-of-time category-aware processing with a content-free visible notification. The fallback preference, Notification Rules, categories, and message content are never sent to Convex; backend wakeup and routing behavior remain unchanged.

The account UI lets users enable categories and then requests local alert authorization. Denied authorization does not expose rules or message data and leaves the encrypted preference available for later use if the user enables notifications in system settings.
