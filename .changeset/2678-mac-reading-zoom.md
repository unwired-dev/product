---
'@private-email/localization': patch
'@private-email/macos': patch
'@private-email/mail-core': patch
'@private-email/mobile': patch
---

On the Mac, Settings gains a Mail group with **Reading**: Text Size follows macOS, and **Message zoom** zooms received formatted mail in the reader from 50% to 300%, kept on this Mac only. The message and Drafts don't change, and an open message keeps its selection as the zoom changes. Remote images further down a message taller than the reader now load as they come near on the Mac too (#2678, #2680).
