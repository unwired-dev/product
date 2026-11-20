---
'@private-email/macos': patch
'@private-email/localization': patch
---

On Mac the Outbox is a sidebar row after Sent while the window's Mail Profile has a message in it, instead of rows at the top of the Inbox column. Selecting it lists the messages under the heading Outbox with a subtitle counting those waiting and those not sent; when the last one leaves, the list returns to All Inboxes. VoiceOver hears where each message stands whichever list the window shows (#2421, part of #2101).
