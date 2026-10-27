---
'@private-email/macos': patch
---

Keep the selection in the Mac composer body after Command-B, I or U or a format bar
button formats it. Before, the selection quietly moved to the end of the message, so
Right did not collapse it and the next Command-B formatted the old selection again
instead of the text typed next.
