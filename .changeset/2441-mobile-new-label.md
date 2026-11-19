---
'@private-email/localization': patch
'@private-email/mobile': patch
---

On iPhone and iPad, **New Label…** after a Gmail message's labels opens **Labels**: type a name, and **Create “Acme” inside “Clients”** creates the nested label in Gmail and applies it, while a name a label already has applies that label. A name another label has in a different case offers **Use “clients/acme”** or **Edit Name** instead of creating a duplicate (#2441, part of #1683).
