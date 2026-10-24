---
'@private-email/macos': patch
'@private-email/mobile': patch
---

Text actions in the reader and composer, such as Summarize, Translate, Load Images, Cc/Bcc, Retry and the Outbox's Undo and Edit, now show feedback while pressed and focused. Pressing one shades it with the subtle selection color. The framework keeps mouse and touch feedback visible for at least 130 ms after press-in, so a quick release or cancellation can leave the highlight visible briefly. Keyboard focus draws a 2 pt accent ring around it, and composer text actions can now be reached by keyboard. Disabled actions stay grey. The labels keep their positions, sizes and hit targets.
