---
'@private-email/convex': patch
---

Harden the Convex backend. Product Account deletion recovery now logs an allow-listed diagnostic before it aborts on a configuration failure or an unexpected defect. Exact encrypted Product Sync reads accept at most 100 identifiers. Identity token segments and Gmail push data are decoded with Effect Schema. The Gmail push HTTP action enqueues wakeups directly instead of calling another action in the same runtime. The unused `deliverGmailWakeups` path, which skipped recipient revalidation, is removed.
