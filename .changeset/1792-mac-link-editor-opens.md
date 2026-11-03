---
'@private-email/macos': patch
---

On Mac, Add Link and Edit Link in the composer's format bar open the Link Editor
popover again; AppKit had declined to show it from the button's zero-height edge.
The editor focuses its Link field, so Escape closes it. Escape, Apply and Remove
Link return focus and the selection to the message body; a click elsewhere keeps
focus where it lands. VoiceOver names each popover by its title.
