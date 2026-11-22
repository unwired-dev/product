---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Warnings, such as Authorization Needed and the Pin indicator, are amber in Light (`#9A5B00`) so they no longer look like the cinnabar On device seal. In Dark the unread dot is lighter (`#7A7E88`) and reaches 4.10:1 on the message list. iPad text uses whole-point sizes in place of the 1.15× fractions, and the shared tokens gain 24pt and 40pt spacing steps and lose the unused sheet and duplicate inset-group radii (#2650).

The On device marker shows the `cpu` symbol in place of the lock, so it no longer reads as Profile Lock or encryption.
