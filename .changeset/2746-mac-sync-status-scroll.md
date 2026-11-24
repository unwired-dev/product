---
'@private-email/macos': patch
---

On the Mac, a Sync Status popover with more connections than the window has room for scrolls its connection list and keeps its title and footer in view, so every Try Again stays reachable (#2746).

A paused connection's Try Again is the frames' 28pt capsule: filled when it can try, a grey title beside the time Gmail named while it waits.
