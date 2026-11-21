---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Gmail's usage limit on the grant verification that activation and refresh run (a 403 for a daily or rate limit, like a 429) now keeps the saved Inbox open from its cache instead of asking to authorize Gmail again. A usage limit's automatic resume first verifies that connection again, as a push wake does, so a connection whose verification met the limit synchronizes at Gmail's time; `createInboxStore` takes that verification as its `verify` option (#2502).
