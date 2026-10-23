---
'@private-email/macos': patch
---

On Mac, the reader confirms a link in a system alert sheet on its own window instead of a custom glass overlay. The sheet shows the full destination, scrolling and selectable when it is long; a flagged link lists its warnings, makes **Cancel** the default (Return and Escape) and shows **Proceed** as destructive. AppKit now owns the question's focus, keyboard and VoiceOver. A confirmation whose message or mailbox changes is withdrawn without acting on it.
