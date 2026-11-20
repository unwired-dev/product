---
'@private-email/localization': patch
'@private-email/macos': patch
---

On the Mac, closing a New Message window that Expand opened asks **Save this Draft?**. **Save Draft** reopens the Draft in the overlay of the Inbox window it came from and brings that window forward. If that window has closed, another Inbox window of the same Mail Profile is used, or a new one opens. When that overlay already holds another Draft, the app first asks **Save Other Draft and Return**. **Discard Draft** deletes the Draft and brings the Inbox window forward, and **Cancel** keeps the window open (#1671).
