---
'@private-email/macos': patch
---

On Mac, Command-B, Command-I and Command-U in composer body paragraphs (not lines that start like a list marker) show their marks on
the selection in the next frame, and text typed after toggling a mark at the caret
appears marked as it is typed instead of turning marked later. Right after focusing
the composer, Undo, Redo, a format bar control or another shortcut, the first
character typed and formatted selections still wait for the composer to redraw.
