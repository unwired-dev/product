---
'@private-email/macos': patch
---

Store a Mac composer's Draft only when the person chooses Save or sends it, as in
Mail. Editing no longer saves or shows a save status. Closing an unchanged Draft
closes at once and an empty one is removed; otherwise the window asks whether to
save the message as a draft, and Don’t Save deletes it. Opening another Draft,
New Message, received mail on compact layouts, Command-W, the window's close button
and Quit ask the same question first.
