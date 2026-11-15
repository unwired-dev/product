---
'@private-email/mail-core': patch
---

Keep reader text inside boxes of sender width when margins, borders, paddings, text indents or letter
spacing inside them would push it out: offsets that would leave less than one glyph become zero, and
widths inside the box leave room for the offsets they keep (#2209).
