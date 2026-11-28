---
'@private-email/mobile': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

On iPhone and iPad, **Settings › Notifications** lists each Mail Profile with a **Badge and sound** switch. A Profile switched off adds nothing to the App Icon Badge, and its New Mail Notifications play no sound. Every switch starts on and stays on this device; while notifications are off, the group is hidden and the choices are kept (#2809, part of #1723).
