---
'@private-email/mobile': patch
'@private-email/localization': patch
---

On iPhone and iPad, toasts are Liquid Glass capsules instead of deep graphite: 48pt tall with a 24pt radius, the symbol and message in the primary text color and the action in the accent ink in Light. On iPhone a message that does not fit one line wraps to a 64pt toast. The refused Undo or Edit toast shows the frames' shorter "Couldn’t return the message to Drafts." (on iPad with the subject); VoiceOver still hears the full sentence (#2591, part of #2104).
