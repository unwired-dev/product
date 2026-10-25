---
'@private-email/mobile': patch
'@private-email/macos': patch
---

The Command Palette fades in over 200 ms while its panel arrives 8pt from above, and fades out over 150 ms when it closes, on iPhone, iPad and Mac. A closing palette takes no further input, reopening it while it fades starts afresh, and Reduce Motion keeps only the fade.
