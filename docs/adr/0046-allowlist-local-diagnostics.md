---
status: accepted
---

# Allowlist device-local diagnostics

Advanced diagnostics are assembled on the trusted device from an explicit allowlist of app,
build, operating-system, backend-schema, Product Sync availability, provider type, coarse mailbox
sync phase, and last-success values. The app does not collect arbitrary logs and attempt to redact
them afterward. Reports exclude mailbox addresses and identifiers, message content, provider
credentials, Categories, raw failure descriptions, and Product Sync plaintext. Raw backend health
checks, environment details, environment switching, and test controls remain debug-only.

Rebuilding local indexes removes provider-derived metadata and then resynchronizes it. Clearing
local mailbox data additionally removes cached message bodies and downloaded incoming
attachments. Both operations preserve provider mail, device-held provider credentials, Drafts,
Product Sync records and key material, Pending Provider Actions, and Outbox deliveries. This may
temporarily make locally cached mail unavailable while offline, so both actions require explicit
confirmation and report resynchronization as pending until connectivity and authorization permit
it to finish.
