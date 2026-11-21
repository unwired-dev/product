---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/macos': patch
---

On the Mac, **Edit Favorites…** in the Favorites header's menu, or Edit Favorites in the Command Palette, lets the sidebar show or hide each Favorites row and reorder them until **Done**; All Inboxes stays shown. The Profile's choice is kept in its Inbox preferences and synchronized through Private Sync, and each Unified Mailbox can be opened from the Command Palette (#2593, part of #2106). `createInboxPreferences` adds `favorites` and `setFavorites`; `favoriteRows`, `toggleFavorite`, `moveFavorite` and `sidebarCommands` are new.
