---
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/mail-core': minor
'@private-email/localization': patch
---

Add a searchable command palette for supported app actions, with a persistent Mac and iPad entry, a phone header gesture, and commands that retain their original message target.

Explain unavailable Compose actions without implying that waiting will unblock them, and prompt for a message selection to match the supported action targets.

Keep failed Reply, Reply All, and Forward commands open with visible feedback in the palette, while cancelled responses stay quiet and reader buttons retain their existing error alert.

Keep palette entry and the phone hint inside supported screens, and keep Reply All searchable with an unavailable reason when no message is open.

Respect provider-specific organizing actions and folder availability in the palette. Keep supported Microsoft actions visible with an unavailable reason when their destination folder is missing.

Show the current response prerequisite in the palette when message content, Draft storage, or a sending mailbox is unavailable.

Show composer finishing failures inside the palette, including New Message, and keep unavailable organizing commands discoverable for supported providers. Retire pending command sessions when their Account, Profile or lock scope changes.

Discard the saved native focus target when an Account, Profile or lock change retires the palette; retain focus restoration on normal dismissal.
