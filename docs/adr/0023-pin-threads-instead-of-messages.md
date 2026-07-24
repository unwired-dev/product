# Pin Threads instead of messages

Pins identify mailbox-scoped Threads through Stable Thread Identity rather than individual messages, trading message-level precision for conversation-level continuity in the unified pinned view and reader toolbar. Legacy message Pins migrate idempotently to their containing Thread and are removed only after the Thread Pin is durably synchronized; pinning makes the Thread's non-Spam, non-Trash body text eligible for bounded encrypted prefetch while attachments remain on demand and the device cache limit still wins.
