---
'@private-email/localization': minor
'@private-email/mail-core': minor
'@private-email/macos': patch
'@private-email/mobile': patch
---

Message dates follow the device's time zone instead of UTC. The reader's header on Mac and iPad
says `Today, 8:12`, `Yesterday, 8:12`, `Sun 11 Oct, 21:14`, or the date with its year, in the
interface language's conventions; iPhone's compact header names the day as its list row does.
VoiceOver reads the full date and time. Message rows, the list's day dividers and Only Mail from
Today use the same day, which changes at local midnight and with the device's time zone. The
native language settings now report `timeZone`, and `messageDateSections` and `filterMessages`
take it. A response still quotes a full UTC date for a message without a Date header (#2102).
