---
'@private-email/macos': patch
---

Mac Settings › Signatures stores a format or link change at once, though the editor keeps focus. A signature stored on another device that replaces the editor's text closes an open Link Editor, and after a refused change or Delete, leaving the editor without an edit keeps a signature another device stored meanwhile (#2076, part of #850).
