---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/mobile': patch
---

On iPhone and iPad, **Outdent** and **Indent** follow the list buttons in the Format panel and the format bar, and a hardware keyboard's Tab and Shift-Tab do the same inside a list. Lists nest three levels deep, each change is one Undo step, and sent mail nests the lists. The Semantic Message Document's list blocks gain an optional `indent` (1 or 2), `listIndentAt` and `indentList` change it, and `listNumbersOf` counts numbered items per level (#2465, part of #1679).
