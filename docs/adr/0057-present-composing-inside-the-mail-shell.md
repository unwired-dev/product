---
status: accepted
---

# Present composing inside the mail shell

## Mac save decision amendment, 2026-10-30

The owner-approved [#991 design](https://github.com/unwired-dev/product/issues/991)
and [#1609 slice](https://github.com/unwired-dev/product/issues/1609) supersede the
Mac autosave and automatic parking clauses below. The regular Mac composer keeps
authored edits local until Save on Close or Send stores them. Close asks before
abandoning changed content; Don’t Save deletes the Draft. Expand retains its
explicit save before handing the Draft to a new window. The
[Draft guide](../drafts.md#saving) owns the complete close and navigation contract.

This accepts loss of edits if the app ends before they are stored, matching the
Mac evaluation composer's save model. The iPhone and iPad save model, encrypted
storage, account and Profile ownership, conflict preservation and durable Outbox
admission remain unchanged. This amendment chooses no provider Draft transport
or replacement body editor and does not qualify native sheet behavior.

## Mac composer window amendment, 2026-10-24

The owner-approved [#1058 design](https://github.com/unwired-dev/product/issues/1058)
and [#1266 slice](https://github.com/unwired-dev/product/issues/1266) supersede the
Mac expansion and collapse clauses below. The Mac composer starts in the same
nonmodal overlay. Expand saves the Draft, opens it in its own native New Message
window and closes the overlay, with no return or Collapse action. Failed saving
keeps the overlay open. The new window starts a new editor and Undo history,
retains Close/Save guards, and is not restored by AppKit. The Inbox remains usable
and several New Message windows may be open. AppKit owns window identity,
resizing, lifetime and command routing. The iPad and compact iPhone contracts
below are unchanged. [The Draft guide](../drafts.md#composing) owns the observable
contract. Draft storage, Product Account and Profile ownership, encryption and
delivery boundaries remain unchanged.

Composing is navigation-owned editor state rather than modal presentation. On iPad, Mac, and other regular-width layouts, a new message, reply, forward, or product-authored Draft starts in a bottom-anchored nonmodal overlay contained by the detail column, leaving the sidebar and thread list visible and interactive. Expanding the same composition session takes over the entire app surface rather than only the detail column; collapsing restores the detail-column overlay without recreating the editor or Draft. On compact iPhone layouts, the mail shell pushes the composer into its existing navigation stack as an editor destination. Adaptive layout changes preserve the same composition identity, Semantic Message Document, selection, focus, undo history, and autosave state. The client does not use a sheet or full-screen cover for these composer states, and selecting a product-authored Draft enters editing directly with no read-only Draft screen.

While the regular-width composer is collapsed, the sidebar and Thread list remain interactive and the covered detail column does not. Selecting another Thread updates the reader behind the composer without dismissing or resetting its Draft. Closing reveals the latest selected Thread; expanding temporarily makes the composer the app-wide interaction surface.

The collapsed overlay spans the detail column with 12-point outer insets and uses 70 percent of its available height, clamped from 420 through 720 points. The composer has only this overlay state and its full-app expanded state, with no freeform drag resizing. Its direct control toggles those states and remains visible in both; compact iPhone omits it because the pushed editor already fills its navigation destination.

Expansion is transient to the open editor and never changes how a later Draft opens. Compose preference schema version 2 ignores and omits the legacy synchronized partial-height or full-screen opening field. Version 1 clients reject that newer payload, so they cannot recreate the retired preference.

## Platform control placement amendment, 2026-10-14

The #903 review decision panel preserves the platform control placement in
[the Draft guide](../drafts.md#composing) and the Compose design frames. This
supersedes the earlier requirement that only the header remain fixed and every
other control scroll. The compact header remains fixed, with a visible `x`
Close control labeled "Close Composer," a left-aligned Draft title, overflow and the regular-width
expansion control. On iPhone and iPad, Send stays at the trailing header edge
and From in a fixed row beneath it. On Mac, From and Send share the fixed bottom
row. Formatting controls remain fixed beneath the header on Mac and iPad and
above the keyboard on compact iPhone.

Recipients, subject, the authored body, attachments, quoted text, assistance
panels, save status, errors and confirmations share one outer content scroll
view. Variable-height feedback must scroll away rather than consume the editor
viewport. The rich body editor grows with its content and never owns a competing
internal vertical scroll.

Each mail window owns one active composer. The `x` closes the editor only after its latest autosave succeeds and never discards the Draft; Discard remains an explicit destructive overflow action. Starting another message or selecting another product-authored Draft autosaves and parks the current Draft, then switches the same editor to the requested Draft. A save failure blocks closing or switching and remains visible inline.
