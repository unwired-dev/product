---
'@private-email/mobile': minor
'@private-email/macos': minor
---

Redesign composing on iPhone, iPad and Mac to match the design: the body comes
first, then attachment chips and the Subject, To, Cc and Bcc rows; the format bar
uses SF Symbols with a Text style menu; From is a pop-up menu; and the
regular-width iPad and Mac composers overlay the reader with Expand and Collapse
instead of replacing it. Selecting another message keeps the open Draft and
updates the reader underneath it. On iPhone, leaving the composer or a reader,
including through the Command Palette's Inbox and Search Mail, returns to the
Inbox instead of an empty reader. On iPhone and iPad, closing or discarding an
untouched New Message closes the composer instead of leaving "This Draft is not
available."
The iPad Commands pill uses a 44pt glass touch target.
Closing or discarding an untouched Mac Draft also clears its composer after removal.
The floating search bar hides while composing; Mac Search Mail reveals it while
keeping the Draft open. The iPad overlay follows the current reading column as
native sidebars move or hide.
