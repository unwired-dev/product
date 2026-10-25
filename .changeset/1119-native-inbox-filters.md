---
'@private-email/mobile': patch
'@private-email/mail-core': patch
---

Inbox Filters open in the native SwiftUI sheet on iPhone and compact-width iPad, and in a native popover on the Filter control in a regular-width iPad window. Escape on a hardware keyboard closes the popover. The theme drops the unused `radius.popover` token, since the system popover owns its corner radius.
