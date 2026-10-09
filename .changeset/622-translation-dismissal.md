---
'@private-email/mobile': patch
'@private-email/macos': patch
---

Discard queued reader translation controls when their preview is dismissed, so
they cannot restart translation or close or cancel a later preview.
Cancel and Retry controls for a superseded request also leave its replacement alone.
