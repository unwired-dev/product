---
'@private-email/mail-core': patch
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

Redesign Settings on the Mac, iPhone and iPad (#906). With a connected Inbox, the
account page is now Settings: Account & Devices, Email Accounts, Language and
Privacy & Data, in the design's grouped rows with section titles, footers, push
buttons and a Mail Assistance switch. The Mac and iPad show a glass sidebar of
destinations beside the selected one; iPhone lists them and pushes one at a time
with a way back, opening on Account & Devices while setup waits there. Per-mailbox
remote content choices now sit with the device policy in Privacy & Data, which
also states that Known Tracking Pixels stay blocked. Only settings the clients
support appear; the welcome flow keeps its layout. Removing another Trusted
Device starts with a confirmation dialog and retains the required
replacement Recovery Key confirmation afterward.
