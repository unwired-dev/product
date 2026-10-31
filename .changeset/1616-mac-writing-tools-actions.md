---
'@private-email/mail-core': minor
'@private-email/macos': minor
'@private-email/mobile': patch
---

Add Proofread, Break into Paragraphs, Expand Text, Shorten Text, Make More
Friendly and Make More Neutral to the Mac composer's Writing tools menu, grouped
as the approved design shows. Each runs its own on-device model operation on the
selection or the whole authored body and opens the same review panel as Rewrite,
under its own title. The assistance core exports `textTools`, `TextTool` and
`isTextTool`; `rewriteInput` takes the tool, and `NativeAssistance.rewrite`
receives each tool's operation in its request. The Mac pop-up control accepts
item sections separated in its menu.
