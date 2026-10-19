---
'@private-email/mobile': patch
'@private-email/mail-core': patch
---

Use native iPhone navigation so Back reveals the preceding screen, Mailboxes fills the viewport, Settings buttons share the gesture destination, and phone controls stay compact with safe horizontal insets in landscape. Keep Draft close confirmation, suppress Welcome during account restoration, and open connected mail while optional private-data recovery waits. Keep Account & Devices selected when opening iPad Settings without a specific destination. Position retained native screens over the full viewport so sibling destinations do not divide the height or leave the Inbox toolbar over message rows. Preserve Inbox search, filters, online results and scroll position when returning through Mailboxes. Restore scrolling after the recreated list's viewport and content are measured, and retire a pending restoration when its view, search or filter changes or the person starts scrolling. Clear that presentation when the Product Account or Profile changes.
