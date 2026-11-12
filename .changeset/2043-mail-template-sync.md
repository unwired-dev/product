---
'@private-email/mail-core': minor
---

Synchronize each Mail Profile's Mail Templates through Product Sync (#2043, part of #850).

- Each template is a sealed `profile-template.` record written by compare-and-set; native code adds `pullMailTemplates` and `pushMailTemplate`.
- `createMailTemplates` takes an optional `NativeMailTemplateSync` and gains `synchronize`; `templates` reports which templates are pending. A template another device changed first stays as a conflict copy, and an edit wins over a removal.
- The Mac and iPhone/iPad mailbox screens synchronize templates when they open and when the app becomes active or goes to the background.
