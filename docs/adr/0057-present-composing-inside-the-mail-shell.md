---
status: accepted
---

# Present composing inside the mail shell

Composing is navigation-owned editor state rather than modal presentation. On iPad, Mac, and other regular-width layouts, a new message, reply, forward, or product-authored Draft starts in a bottom-anchored nonmodal overlay contained by the detail column, leaving the sidebar and thread list visible and interactive. Expanding the same composition session takes over the entire app surface rather than only the detail column; collapsing restores the detail-column overlay without recreating the editor or Draft. On compact iPhone layouts, the mail shell pushes the composer into its existing navigation stack as an editor destination. Adaptive layout changes preserve the same composition identity, Semantic Message Document, selection, focus, undo history, and autosave state. The client does not use a sheet or full-screen cover for these composer states, and selecting a product-authored Draft enters editing directly with no read-only Draft screen.

While the regular-width composer is collapsed, the sidebar and Thread list remain interactive and the covered detail column does not. Selecting another Thread updates the reader behind the composer without dismissing or resetting its Draft. Closing reveals the latest selected Thread; expanding temporarily makes the composer the app-wide interaction surface.

The collapsed overlay spans the detail column with 12-point outer insets and uses 70 percent of its available height, clamped from 420 through 720 points. The composer has only this overlay state and its full-app expanded state, with no freeform drag resizing. Its direct control toggles those states and remains visible in both; compact iPhone omits it because the pushed editor already fills its navigation destination.

Expansion is transient to the open editor and never changes how a later Draft opens. The legacy synchronized partial-height or full-screen opening preference is ignored after migration, then removed only after the minimum-client generation fences out older clients that still understand it.

Only the compact composer header remains fixed. Its leading control is a visible `x` icon with the accessibility label “Close Composer,” followed by a left-aligned Draft title. The expansion control remains directly visible beside the overflow menu, and Send remains visible at the trailing edge. From identity, recipients, subject, formatting controls, the authored body, attachments, quoted text, and save or error status share one outer scroll view. The rich body editor grows with its content and never owns a competing internal vertical scroll.

Each mail window owns one active composer. The `x` closes the editor only after its latest autosave succeeds and never discards the Draft; Discard remains an explicit destructive overflow action. Starting another message or selecting another product-authored Draft autosaves and parks the current Draft, then switches the same editor to the requested Draft. A save failure blocks closing or switching and remains visible inline.
