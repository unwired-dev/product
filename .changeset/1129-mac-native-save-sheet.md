---
'@private-email/macos': patch
---

On Mac, the Tiptap evaluation editor asks whether to save a changed Draft in a system alert sheet on its own window, with **Save**, **Don’t Save** and **Cancel** (Escape). AppKit now owns the question's focus, keyboard and VoiceOver. A question whose editor goes away, such as when another Product Account opens, is withdrawn without acting on it.
