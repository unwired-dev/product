---
'@private-email/mobile': patch
'@private-email/macos': patch
'@private-email/mail-core': patch
---

Stop the composer's save status from blinking while you type. Successful saving
on iPhone, iPad and Mac no longer shows **Saving…** or **Saved on this device**;
the composer only says when an edit is not saved, because saving failed or
private storage is locked, and keeps its existing recovery.
