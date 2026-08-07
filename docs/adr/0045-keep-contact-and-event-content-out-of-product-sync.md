---
status: accepted
---

# Keep contact and event content out of Product Sync

The Apple client owns Add to Contacts and Add to Calendar extraction, permission requests, review, Contacts and Calendar reads, and operating-system writes. It detects a Contact Candidate only from the name and email address in message headers for People-classified direct correspondence with reply evidence; a body already available locally may add fields but cannot establish candidacy, and detection never fetches a missing body. Independently, it detects a Calendar Event Candidate from a structured calendar invitation or, in the later prose-detection increment, from an unambiguous date and time in a body already available locally. Detected fields, Apple Contacts contents, Calendar contents, and calendar-event mappings remain device-local and do not enter Product Sync. The TypeScript backend may transport only opaque encrypted **Feature Suggestion Preference** data, with one separate synchronized preference for each proactive feature, plus type-level suppressions and dismissal identifiers through End-to-End Encrypted Product Sync; it never stores extracted fields or operating-system records.

Contacts and Calendar remain authoritative for committed records. The client requests each operating-system permission only when the user acts, requires review before creating, merging, updating, or removing data, never overwrites a non-empty Contact field automatically, and checks iCalendar identity before adding or updating a structured event.
