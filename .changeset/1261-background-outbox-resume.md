---
'@private-email/mobile': minor
---

On iPhone and iPad, a queued message can reach its provider during a background delivery task iOS grants while the app is closed but not force-quit, keeping its original Undo Send deadline and submitting once; iOS decides when, or whether, that happens.

Background tasks also check interrupted sends against Sent without resubmitting, and leave inconclusive outcomes unknown.
