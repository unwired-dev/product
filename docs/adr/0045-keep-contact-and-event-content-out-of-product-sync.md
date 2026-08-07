---
status: accepted
---

# Keep contact and event content out of Product Sync

The Apple client owns Add to Contacts and Add to Calendar extraction, permission requests, review, Contacts and Calendar reads, and operating-system writes. It detects candidates on device from message metadata, structured invitations, and bodies already available locally; it never fetches a missing body solely for detection. Detected fields, Apple Contacts contents, Calendar contents, and calendar-event mappings remain device-local and do not enter Product Sync. The TypeScript backend may transport only opaque encrypted feature preferences, type-level suppressions, and dismissal identifiers through End-to-End Encrypted Product Sync; it never stores extracted fields or operating-system records.

Contacts and Calendar remain authoritative for committed records. The client requests each operating-system permission only when the user acts, requires review before creating, merging, updating, or removing data, never overwrites a non-empty Contact field automatically, and checks iCalendar identity before adding or updating a structured event.
