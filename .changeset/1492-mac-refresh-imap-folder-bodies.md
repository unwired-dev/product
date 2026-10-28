---
'@private-email/macos': patch
---

On Mac, View › Refresh and Try Again synchronize each IMAP connection before reading the listed folder again, so a listed folder the cache evicted keeps its saved message bodies (#1492).
