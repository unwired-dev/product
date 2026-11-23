---
'@private-email/mobile': patch
---

The iPhone and iPad Remind Me to Send choices name the time zone in full on device, as in "Times in
Central European Standard Time (Prague)", instead of only "Central": Hermes on Apple splits
`formatToParts` at each space, so the line now takes the name from the formatted date (#2147).
