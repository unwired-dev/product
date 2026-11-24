---
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

An open online search stops listing a message once its provider confirms it deleted (Gmail and Microsoft history, Gmail's expired-history check, or an IMAP server that no longer has it), without searching again. The other results keep their order and their next page. IMAP Inbox snapshots now carry their held search results as `found`, as Gmail's and Microsoft's do (#2451).
