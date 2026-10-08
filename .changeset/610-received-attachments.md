---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Download, open and share received Gmail attachments on iPhone, iPad and Mac (#610).

- **Listing:** an opened message lists its attachments with names, sizes and availability, without making attachment requests. Gmail can include small attachment bytes in the bounded MIME response needed to open the body; the cache retains only descriptors. The list is kept with the encrypted body, so it also shows offline. Names cannot hide their real extension or leave their folder.
- **Download:** each attachment downloads only when asked, through its own mailbox's Gmail connection. It is kept only when its bytes decode to exactly the declared size; incomplete or damaged copies are refused. Downloads can be cancelled and retried, and attachments over 25 MiB are listed without a download.
- **Open and share:** a downloaded attachment opens in the system's Quick Look preview, or shares through the system share sheet, with only that file.
- **Cleanup:** downloaded files stay in private Application Support storage, outside backups, bounded to 250 MiB with oldest-file eviction. They are deleted when the message's last reader closes, the message leaves the Inbox, the Inbox closes or changes owner, the mailbox is removed, the person signs out, the account is deleted, the device is removed, or the app relaunches.
