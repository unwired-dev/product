---
'@private-email/localization': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

Settings › Mail Profiles shows a queued change while it runs. The control that
started it shows an activity indicator: a mailbox move reads **Moving to
<Profile>…** on the Mac, and the indicator replaces the pop-up on iPad and iPhone.
Add Mail Profile…, the Name field, the mailbox pop-ups and Remove Mail Profile…
are disabled until the change completes or fails. Disabled Settings rows now dim
to 40%.
