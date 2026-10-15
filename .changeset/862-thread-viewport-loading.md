---
'@private-email/mail-core': minor
'@private-email/mobile': minor
---

Load Thread bodies by what the reader shows on iPhone and iPad. The opened message loads first, then the messages in view, then the rest by distance from the viewport, and scrolling reorders reads that are still waiting without changing each connection's two concurrent body loads or the device-wide four. Every message of the Thread is brought onto the device, but only bodies within one viewport of the visible range are mounted, so a long Thread no longer creates a body view and rich document for every message at once. The opened message now stays in place while the bodies above it load, until you scroll.
