---
'@private-email/localization': patch
'@private-email/mail-core': patch
---

Mac, iPad and iPhone explain a new-device approval that didn’t finish: after **Approve Device** fails, the card now says approving the new device didn’t finish and to choose Approve Device to try again, and after **Decline** fails it says declining didn’t finish and to choose Decline, instead of "The device could not be approved. Try again." for both. `EnrollmentFailure` gains `decline-failed` (#2297, part of #2006).
