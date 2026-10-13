---
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
'@private-email/mail-core': patch
---

Redesign message reading on Mac, iPad and iPhone to match the design (#902).

- **Toolbar:** the reader's organizing and response actions are SF Symbol buttons in Liquid Glass groups. The Mac keeps a fixed toolbar above the reading pane: Archive, Move to Trash and Labels or Folders, then Reply, Reply All and Forward, then the remaining actions. iPad places Archive, Labels or Folders, the response actions and More in a fixed toolbar above the reading pane. iPhone floats Archive, Labels or Folders, Reply and More over the bottom of the reader beside a circular New Message button. Reply opens a glass-backed modal sheet offering Reply, Reply All and Forward. More lists the remaining actions in a panel.
- **Reading pane:** the subject uses Reading Subject, Mac shows the sender and address on one line with the received time trailing, and the body stays at Reading Body. iPhone adds a header with a glass Back pill carrying the mailbox's cached unread count and the truncated subject, an "N Messages" row in the Thread view, and neutral monogram initials beside each message's sender. Thread messages use the same header.
- **Attachments and links:** received attachments are quiet-fill chips with a document symbol, name, size and actions. Link confirmations are centered modal glass alerts with a link or warning-shield symbol, the title "This link may not be what it seems" for suspicious links, and stacked Cancel, Copy link and Proceed choices.
