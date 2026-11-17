---
'@private-email/localization': patch
'@private-email/mail-core': patch
---

Mac, iPad and iPhone explain a Trusted Device removal step that didn’t finish: Trusted Devices now says preparing the removal, removing the device or cancelling the removal didn’t finish, and names **Remove…**, **Remove {name}** or **Cancel** to try again, instead of "The device could not be removed. Try again." for all three. `RevocationFailure` gains `prepare-failed` and `cancel-failed`, and `revocationNotice()` takes the failure instead of a boolean (#2299, part of #2006).
