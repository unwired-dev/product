---
status: accepted
---

# Make Inbox Cleanup reviewed and recoverable

Inbox Cleanup will detect candidates on device and present a reviewable proposal rather than deleting mail automatically. A proposal selects individual eligible Inbox messages, may select a whole Thread only when every current message qualifies, and requires a final action that states how many messages will move to the Mail Provider's Trash; permanent erasure is outside this feature.

A Unified Inbox proposal may span Mailbox Connections, but execution reuses the existing durable Provider Mail Action boundary and reports each connection's outcome without claiming a cross-provider transaction. Immediately before enqueueing, the client revalidates every candidate and skips mail that has become unread, pinned, recategorized, replied to, or otherwise ineligible. One proposal contains at most 500 messages, explains each group in plain language, and permits deselection; successful moves offer immediate Undo when supported, while provider Trash remains the longer recovery boundary.

The card appears only when one sender has at least ten eligible messages or the selected Inbox has at least fifty candidates. Not Now applies a 30-day cooldown unless the candidate count doubles. The first release keeps these thresholds fixed and exposes enablement and suppression settings rather than speculative rule tuning.
