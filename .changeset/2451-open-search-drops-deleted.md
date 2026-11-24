---
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

An open online search stops listing a message once its provider confirms it deleted (Gmail's history or its expired-history check, or an IMAP change made on this device that moves it out of its folder or finds it no longer on the server), without searching again. The other results keep their order and their next page. IMAP Inbox snapshots now carry their held search results as `found`, as Gmail's do (#2451).
