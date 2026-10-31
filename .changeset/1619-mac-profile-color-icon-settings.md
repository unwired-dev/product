---
'@private-email/mail-core': minor
'@private-email/localization': patch
'@private-email/macos': patch
---

Mac Settings › Mail Profiles chooses a Profile's Color and Icon from system
pop-ups after its name, and lists each Profile with its styled monogram: a
circle in its Color with its Icon or first letter in white. The Primary Profile
shows Graphite and First Letter. Shared mail-core adds the Profile Color tokens
(`profilePalette`), the ordered `profileColors` and `profileIcons` with each
Icon's SF Symbol, and a `restyle` refusal. Native pop-up menu items accept a
`symbolColor`.
