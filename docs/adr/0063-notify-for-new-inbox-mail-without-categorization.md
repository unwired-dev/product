---
status: accepted
---

# Notify for new Inbox mail without categorization

The focused replacement release includes notifications but defers categorization.
After a person grants notification permission, new Inbox messages may notify,
subject to per-Mailbox Connection switches. Historical synchronization never
generates new-mail alerts. This replaces the category-eligibility prerequisite
in [ADR 0008](0008-device-evaluated-category-aware-notifications.md) for the new
client so notifications do not depend on a deferred feature.

Use generic notification content by default; sender and subject previews require
explicit opt-in. Eligibility and content remain device-evaluated, and neither
message content nor readable Notification Rules enter the backend. Generic
content is the normal first-release presentation, not the old category-failure
fallback. The existing Swift client's category-based behavior remains documented
in ADR 0008 until that implementation is retired.
