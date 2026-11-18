---
'@private-email/mobile': minor
'@private-email/localization': patch
---

iPhone and iPad disable Send while the Draft cannot be sent as it is, and say why before Send is pressed (#2396, part of #2092).

- **Add a recipient to send.** shows under To, or on one line above a docked iPad reply's From and Send; text that is not an address says it is not a complete address once its field is left. VoiceOver reads the reason with Send.
- A sending mailbox that needs sign-in again shows the Authorization Needed banner under From, with **Sign In…**; the Sent folder, file and other sender problems show among the composer's notices.
