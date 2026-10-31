---
'@private-email/mail-core': minor
'@private-email/macos': patch
---

The Mac Profile Switcher and Profile Menu show each Mail Profile's styled
monogram: a circle in its Color with its Icon or first letter in white, the
Primary Profile in Graphite. Shared mail-core adds `profileStyle` and
`profileLetter`, a `fills` option on `profileMenu`, and an optional `monogram`
on menu items, which native Mac menus draw as the item image.
