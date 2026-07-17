---
status: accepted
---

# Use local-first metadata and a bounded encrypted body cache

Mailbox views will read Durable Message Metadata from local persistence immediately while provider synchronization updates it in the background. A newly connected mailbox becomes usable after metadata for its newest 50 messages arrives; resumable historical metadata backfill then paginates through the complete provider-visible history with separate progress, and body prefetch starts without delaying initial availability. Backfill pauses under low storage, low power, or network loss. For each Mailbox Connection, the client will prefetch at most the newest 500 Inbox and Sent message bodies from the last 30 days plus pinned message bodies regardless of those selection cutoffs. Spam, Trash, attachments, and older unpinned bodies remain on-demand. The encrypted body cache has a 500 MB device-wide hard limit and evicts opened older bodies first, then the oldest non-pinned prefetched bodies, and finally least-recently-read pinned bodies; pin metadata survives eviction and draft bodies are stored separately. This supersedes ADR-0005's on-demand-only body-fetch policy, trading additional device storage and background work for fast list rendering, faster message opening, and bounded offline reading.
