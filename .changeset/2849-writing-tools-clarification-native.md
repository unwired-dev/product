---
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

Rewrite, Expand Text, Shorten Text, Make More Friendly and Make More Neutral now ask for clarification instead of guessing. Before generating, the on-device binding asks the model in a separate guided session whether the text can be edited without guessing a material fact or intent; when it cannot, the composer shows the clarification card and the Draft stays unchanged. Other text is edited exactly as before. The assistance qualification corpus is version 5, with cases that must and must not ask (#2849).
