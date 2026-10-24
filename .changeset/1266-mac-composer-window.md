---
'@private-email/macos': minor
'@private-email/localization': patch
---

Expand in a Mac window's composer saves the Draft and moves it into its own New
Message window, closing the overlay. Closing that window or quitting asks its
composer first, including in the regular editor. A refused save or unfinished
recipient keeps the window open and cancels Quit. The window closes itself once
no Inbox can open.
