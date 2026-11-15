---
'@private-email/mail-core': patch
---

Keep reader text inside sender boxes, so it cannot overflow under an inline image or onto a button
fill: fixed heights become minimums outside tables, maximum heights are removed, lines holding text are
at least as tall as their font, and boxes of sender width bound the widths inside them (#2204).
