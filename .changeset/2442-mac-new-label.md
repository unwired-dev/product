---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

On the Mac, **New Label…** in a Gmail message's **Labels** menu opens the **Labels** popover in place of the name alert: type a name, and **Create “Acme” inside “Clients”** creates the nested label in Gmail and applies it, a listed label applies at once, and a name another label has in a different case offers **Use “clients/acme”** or **Edit Name** in a sheet. iPhone, iPad and Mac share the naming rules through `typedLabel` in `@private-email/mail-core/gmail-actions` (#2442, part of #1683).
