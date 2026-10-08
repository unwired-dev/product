---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Download, open and share received Gmail attachments on iPhone, iPad and Mac (#610).

- **Listing:** an opened message lists its attachments with names, sizes and availability, without making attachment requests. Rows appear 20 at a time with Show N more for the rest. Gmail can include small attachment bytes in the bounded MIME response needed to open the body; the cache retains only descriptors. The list is kept with the encrypted body, so it also shows offline. Names cannot leave their folder. Very long sender names are reduced before Unicode cleanup. Shortened names keep a short final suffix or use underscores for dots, so an earlier suffix cannot become the file extension.
- **Download:** each attachment downloads only when asked, through its own mailbox's Gmail connection. It is kept only when its bytes decode to exactly the declared size; incomplete or damaged copies are refused. Downloads can be cancelled and retried, and attachments over 25 MiB are listed without a download.
- **Open and share:** a downloaded attachment opens in the system's Quick Look preview, or shares through the system share sheet, with only that file.
- **Cleanup:** downloaded files stay in private Application Support storage, outside backups, bounded to 250 MiB with oldest-file eviction. Reader, message and Inbox cleanup waits until active Quick Look previews and shares finish; those files also stay through eviction and count toward the limit. A download that cannot fit around them can be retried after the presentation ends. Mailbox removal, sign-out, account deletion, device removal and relaunch delete files immediately.
