---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Rich email bodies now follow the app's Light or Dark appearance on iPhone, iPad
and Mac instead of showing a white canvas in Dark mode. The reader uses the
shared content background, primary text and link colors, restyles an open
message when the appearance changes, and still removes sender colors (#977).
