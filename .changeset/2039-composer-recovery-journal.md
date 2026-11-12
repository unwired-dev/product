---
'@private-email/mail-core': patch
'@private-email/mobile': minor
'@private-email/macos': minor
---

Composers journal unsaved edits to a recovery record (#2039, part of #1989).

- The iPhone, iPad and Mac composers keep their unsaved version in the composer recovery record two seconds after an edit and when the app returns to the foreground, retrying a record locked storage refused. Save Draft, Save, Send, Delete Draft, Don’t Save, Discard and a Close that removes or leaves the Draft remove it. Nothing is offered at launch yet.
- mail-core `journal` writes nothing for a Draft the current Product Account's session never listed, and `forget` takes the closing editor so a record stays for another editor still open on that Draft.
