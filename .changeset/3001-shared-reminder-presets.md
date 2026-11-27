---
'@private-email/mail-core': minor
'@private-email/macos': patch
'@private-email/mobile': patch
---

Mac, iPhone and iPad offer the same Send Reminder times (#3001): This Evening at
18:00 while it is still ahead, Tomorrow Morning at 8:00, This Weekend on Saturday
at 9:00 from Sunday to Thursday, and Next Week on Monday at 8:00. The Mac gains
This Weekend and Next Week and moves to 18:00 and 8:00, so Choose Date and Time…
starts tomorrow at 8:00; iPad gains This Weekend. Mail-core's `reminderTimes`
returns these times and replaces `mobileReminderTimes`.
The Mac reminder menu shows each time on its title's line, right-aligned, through
the new menu item `detail`, and wraps its note in small type; the iPhone sheet
shows its grabber and separates its rows. The iPad popover's Cancel is primary text
on the quiet fill.
