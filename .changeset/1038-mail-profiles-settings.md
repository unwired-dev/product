---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

Add Settings › Mail Profiles on Mac, iPhone and iPad, opened from the Profile
Menu's Manage Mail Profiles…. It lists every Mail Profile with its connections
and the Startup Profile, adds a Mail Profile, renames the selected one (the
Primary Profile keeps its name), and chooses the device-local Startup Profile
that new windows open.

Profile creation and renaming wait for registration verification; changing Startup
Profile preserves every already-open window. Each Product Account keeps its own
Startup Profile on this device.

Match the approved Profile row disclosures and Add action tint, and keep Profile
name editing and the mobile Startup Profile picker at the platform's minimum
interaction size.
