---
'@private-email/mail-core': minor
'@private-email/macos': minor
'@private-email/mobile': patch
---

Add Generate a Draft… to the Mac composer's Writing tools menu. It opens a
popover for a prompt; Generate asks the on-device model, through its own
`generate` operation, to write email text from the prompt alone, and the result
opens in the review panel, where Insert places it at the caret as one undoable
edit without replacing text. The assistance core exports `canGenerate`,
`captureDraftText` takes the prompt, and its purposes include `generate`.
