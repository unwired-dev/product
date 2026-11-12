---
'@private-email/mail-core': minor
---

Synchronize each Mail Profile's Mail Templates through Private Sync (#2043, part of #850).

- Each template is a sealed `profile-template.` record written by compare-and-set; native code adds `pullMailTemplates` and `pushMailTemplate`.
- `createMailTemplates` takes an optional `NativeMailTemplateSync` and gains `synchronize`; `templates` reports which templates are pending. When another device changed a template first, its version keeps the id and this device's edit stays as a conflict copy; an edit wins over a removal.
- The Mac and iPhone/iPad mailbox screens synchronize templates when they open and when the app becomes active or goes to the background.
