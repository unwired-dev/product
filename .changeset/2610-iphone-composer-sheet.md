---
'@private-email/mobile': patch
---

On iPhone the composer is the system sheet over the mail it was started from. Swiping the sheet down is the same as **Close**: an unchanged Draft closes, an empty one is removed, and changed content asks **Delete Draft** or **Save Draft** first while the sheet stays open. The sheet's downward swipe belongs to the system, so the composer no longer opens the Command Palette on iPhone, as the app's other sheets do not (#2610).

On iPhone and iPad, **Delete Draft** and **Save Draft** open over **Close** and visibly grow out of it, from a fifth of their size, as a system menu opens over its button; a tap outside them keeps editing (#2610).

On iPhone the composer header matches the Compose frame: Send sits 16pt from the edge rather than 24pt, the title is centred, and in the sheet From sits directly under the header (#2610).
