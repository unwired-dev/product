---
'@private-email/macos': patch
---

Mac Sign In fits windows narrower than its frame: below the frame's width the form gives
up its 200pt inset first, then its width, so the sign-in actions stay whole beside the
brand panel down to the 760pt minimum window.
