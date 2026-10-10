---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Load a message's remote images on request. Under the default Ask policy, the
reader explains that loading reveals the device's IP address and when the
message was opened, and offers Load images for that presentation; Never and
Always load can be chosen for this device and for each Gmail mailbox on the
account page. Images load only near the visible part of the message, six at a
time per message and twelve across the account, through a native HTTPS fetch
outside WebKit without cookies or credentials that refuses non-public
destinations, pins one validated address while authenticating the original host,
and repeats those checks for every redirect. Validated images are kept in a
separate 250 MB encrypted cache scoped to each account, mailbox, message and
source, which Clear remote content empties. Known tracking pixels never load.
