---
'@private-email/macos': patch
---

Mac labels expose an accessibility frame that hugs their text instead of spanning the column, so VoiceOver and the accessibility audit find each label where it is drawn. This also applies to Inbox month headers and the empty reader prompt.
