# Require trustworthy mailbox role mapping

Unified Mailboxes will normalize provider mailboxes and labels through canonical Mailbox Roles. Provider-native semantics and IMAP `SPECIAL-USE` markers are trusted when unambiguous; otherwise connection setup asks the user to map required roles and permits later changes. The product accepts additional setup friction and will not guess from localized folder names, avoiding incorrect sent-mail placement and destructive actions against the wrong folder. See [RFC 6154](https://www.rfc-editor.org/rfc/rfc6154.html).
