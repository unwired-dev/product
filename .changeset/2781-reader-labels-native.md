---
'@private-email/mobile': patch
---

A Gmail reader's labels open in native presenters instead of a glass panel: on iPhone, More's
Labels and the Reply sheet's Labels open a system sheet, and New Label… opens its own sheet once
that one closes; on iPad, the toolbar's Labels opens a system popover, where New Label… takes the
labels' place. A tap outside closes either one, as the system does (#2781, part of #1056).
