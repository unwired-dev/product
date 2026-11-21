---
'@private-email/mobile': patch
---

On iPhone the composer is the system sheet over the mail it was started from. Swiping the sheet down is the same as **Close**: an unchanged Draft closes, an empty one is removed, and changed content asks **Delete Draft** or **Save Draft** first while the sheet stays open. The sheet's downward swipe belongs to the system, so the composer no longer opens the Command Palette on iPhone, as the app's other sheets do not (#2610).

On iPhone and iPad, Close asks **Delete Draft** or **Save Draft** in the system action sheet, which grows out of **Close**; **Cancel** or a tap outside it keeps editing (#2610).
