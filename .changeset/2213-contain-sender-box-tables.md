---
'@private-email/mail-core': patch
---

Keep reader text inside boxes of sender width when a table or a glyph wider than the box would push
it out: tables share the box between their columns, words longer than a line of the box may break
anywhere, and text shrinks to the box down to the readable minimum, which a narrower box widens to
hold (#2213).
