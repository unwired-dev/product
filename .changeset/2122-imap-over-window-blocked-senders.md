---
'@private-email/mail-core': patch
---

Screen IMAP Inbox arrivals beyond the read window for Blocked Senders (#2122, part of #655). When more new mail arrives between synchronizations than the window holds, the older arrivals' envelopes are read in batches before the checkpoint advances and a Blocked Sender's message among them moves to Trash; only the newest window is still cached and notified. The IMAP Inbox's `arrived` callback receives those arrivals as a second `earlier` list.
