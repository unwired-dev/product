---
'@private-email/mail-core': patch
---

Microsoft messages now keep their Outlook categories as labels of their own. The `label` and `unlabel` organizing actions with those labels assign or remove one category through Graph and keep the message's other categories as Microsoft has them (#3019).
