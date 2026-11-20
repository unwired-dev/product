---
'@private-email/mobile': patch
'@private-email/mail-core': patch
---

On iPhone and iPad, **Settings › Notifications** offers an **App Icon Badge** pop-up with **Off** and **Unread in Inbox**. It starts **Off** and stays on this device. With **Unread in Inbox**, the app icon shows how many unread messages this device lists in the Inbox of every open mailbox, updated as mail arrives, is read or is archived, also during background synchronization, and cleared when the choice is **Off**, notifications are turned off, the last mailbox is removed or the person signs out. Asking for notification permission now includes the badge; while notifications are off, the choice stays, dimmed (#2478, part of #1723).
