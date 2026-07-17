# Device-evaluated Category-Aware Notifications

Notification Rules are user-owned encrypted Product Sync data. The Apple client stores the selected category identifiers in one encrypted payload and decrypts them only on trusted devices. Convex stores the opaque payload identifier, ciphertext, nonce, and key version; it cannot read the selected categories or use them to decide which devices receive wakeups.

A Gmail push remains a content-free background wakeup. The receiving device first fetches recent mailbox changes with its device-held Gmail token and runs local System Categorization. It may schedule a visible local notification only for a newly observed, non-historical message whose resulting Message Category matches a decrypted Notification Rule. The visible notification itself does not include the message subject, sender, category, or body.

Notification Rules are empty by default. If local metadata cannot be read, rules cannot be decrypted, categorization produces Uncategorized State, local notification delivery fails, or the app has no safe background execution time remaining, processing fails closed and no visible notification is scheduled. This decision does not add a Generic Notification Fallback; that remains a separate optional feature.

The account UI lets users enable categories and then requests local alert authorization. Denied authorization does not expose rules or message data and leaves the encrypted preference available for later use if the user enables notifications in system settings.
