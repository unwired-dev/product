---
'@private-email/mail-core': minor
'@private-email/localization': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Show when the Inbox was last brought up to date on iPhone, iPad and Mac (#1444).

- **Subtitle:** when the shown mailboxes are neither syncing nor offline, the Inbox subtitle adds how long ago they were last brought up to date, such as `12 unread · Updated just now` or `Updated 5 minutes ago`. With several mailboxes shown, the oldest last update counts.
- **Recorded per connection:** Gmail, Microsoft and IMAP connections save when their latest completed synchronization started with their encrypted cache, so the time survives relaunch and later failed attempts. Gmail and Microsoft save it at most once a minute.
