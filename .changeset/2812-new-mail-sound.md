---
'@private-email/mobile': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

On iPhone and iPad, **Settings › Notifications** offers a **New Mail Sound** pop-up under **App Icon Badge** with **Default** (the system notification sound) and **None**. It starts at **Default** and stays on this device. New Mail Notifications play the chosen sound, or none; while notifications are off, the choice stays, dimmed (#2812, part of #1723).
