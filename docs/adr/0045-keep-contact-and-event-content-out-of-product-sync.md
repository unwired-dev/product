---
status: accepted
---

# Keep contact and event content out of Product Sync

Add to Contacts and Add to Calendar detect candidates on device from message metadata, structured invitations, and bodies already available locally; they never fetch a missing body solely for detection. Detected fields, Apple Contacts contents, Calendar contents, and calendar-event mappings remain device-local and do not enter Product Sync. End-to-End Encrypted Product Sync may carry only each independent feature's enablement, type-level suppression, and opaque dismissal identifiers so trusted devices can avoid repeating prompts without synchronizing extracted personal data.

Contacts and Calendar remain authoritative for committed records. The client requests each operating-system permission only when the user acts, requires review before creating, merging, updating, or removing data, never overwrites a non-empty Contact field automatically, and checks iCalendar identity before adding or updating a structured event.
