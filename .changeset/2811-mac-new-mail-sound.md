---
'@private-email/macos': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

On the Mac, **Settings › Notifications** groups **Dock badge** and a new **New mail sound** pop-up under **On this Mac**, and lists each Mail Profile's **Badge and sound** switch. New mail sound offers **Default**, the Mac's alert sounds (such as Glass) and **None**; shown New Mail Notifications play the chosen sound. A Profile switched off adds nothing to the Dock badge and its notifications play no sound. The choices stay on this Mac; while notifications are off they stay, dimmed (#2811, part of #1723).
