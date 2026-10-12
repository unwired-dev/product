---
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/mail-core': minor
'@private-email/localization': patch
---

Add a searchable command palette for supported app actions, with a persistent Mac and iPad entry, a phone header gesture, and commands that retain their original message target.

Explain unavailable Compose actions without implying that waiting will unblock them, and prompt for a message selection to match the supported action targets.

Keep failed Reply, Reply All, and Forward commands open with visible feedback in the palette, while cancelled responses stay quiet and reader buttons retain their existing error alert.
