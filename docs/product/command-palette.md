# Command Palette

This document records the product requirements agreed during the Command Palette
design interview. The specification is confirmed; it does not establish implementation or release
readiness.

Canonical vocabulary lives in the [organization glossary](../domain/organization.md).

## Scope

- The first version finds and runs actions, including navigation to app destinations.
- Email content search remains in the existing search interface; email results do
  not appear in the Command Palette.
- The current maintained-client integration covers navigation, Compose, Reply,
  Forward, and supported mail actions including Archive, Move, and Mark Read or
  Unread. It includes app-wide commands and commands for the current individual
  message selection.
- The confirmed product direction also includes Pin, Thread-wide targets, and
  bulk actions. These remain future Command Palette integration work until their
  owning features supply supported actions; see the integration scope below.
- The palette is available in Inbox, message reading, the composer, and Settings.
  Opening it preserves the current screen, selection, and unfinished Draft.

## Desktop entry

- A command input remains visible at the top of the desktop interface while the
  Command Palette is closed.
- Clicking the input or pressing Command-P opens the Command Palette.
- Results open directly beneath the persistent input, overlaying the current
  screen without shifting its layout. The input receives focus immediately.
- Up and Down select a command, and Enter runs it. Existing keyboard shortcuts
  appear beside their commands.

## Phone entry

- The phone interface opens the Command Palette through a gesture only, without
  a visible palette entry button.
- A downward swipe starting on the app header, below the system status bar, opens
  the palette regardless of the content's scroll position. Swipes starting in the
  message list continue to scroll normally.
- A one-time hint says Swipe down on the header for commands. The hint explains
  the gesture without adding a button or another opening method.

## iPad entry

- The command input remains visible in both wide and compact iPad layouts.
- Tapping the input or performing the same header swipe as on phone opens the
  palette. Command-P also opens it when a hardware keyboard is attached.

## Phone and iPad presentation

- Opening the palette reveals a panel attached to the top, with the command input
  focused and matching actions underneath. The software keyboard opens when
  needed for typing.
- Users can tap an action without first typing a query.
- The header exposes an Open Command Palette accessibility action for VoiceOver
  and other assistive controls without adding a visible entry button.

## Current command targets and availability

- Mail commands use the existing individual-message handlers for the selected or
  open message. The palette never silently chooses a message.
- The target message is fixed when the palette opens. Incoming mail or changes
  to the list do not change that target. Command availability is rechecked before
  execution, and a disappeared target is never replaced by another message.
- Commands that cannot currently run remain visible but disabled, with a short
  reason such as Select a message. The palette includes supported app commands
  and does not advertise unimplemented features.

## Future Thread and bulk targets

These confirmed requirements apply when the maintained clients support Thread
and bulk actions; they do not describe the current integration.

- Mail commands act on the selected Threads, or on the open Thread when reading
  one. The palette never silently chooses a message.
- Bulk-capable commands act on the selection. Reply and Forward require a single
  Thread.
- The target Threads are fixed when the palette opens. Incoming mail or changes
  to the list do not change those targets. Command availability is rechecked
  before execution, and a disappeared target is never replaced by another Thread.

## Finding commands

- With an empty query, contextual actions appear first, followed by app-wide
  actions and navigation destinations.
- Typing filters commands by name with fuzzy matching and common synonyms.
- Ordering is predictable; the first version does not personalize results based
  on usage.

## Choosing parameters and executing

- A command requiring another choice, such as Move, opens the corresponding
  picker within the palette. Nothing moves until the destination is chosen.
- Back returns from the picker to the command list.
- Palette commands use the same confirmations, Undo, and error behavior as the
  corresponding buttons or menus.

## Closing and reopening

- Cancel, an outside click or tap, or Escape dismisses the palette. Within a
  parameter picker, Escape first returns to the command list.
- Dismissing restores the previous focus. Successfully running a command closes
  the palette.
- Each new opening starts with an empty query.

## Maintained-client integration scope

The current maintained clients select and organize individual messages. The
palette uses those same message targets and action handlers; it does not claim
thread-wide execution, bulk selection, or Pin support before those features
exist. Those commands can be exposed when their owning launch work supplies
supported actions. [Keyboard and bulk actions #849](https://github.com/unwired-dev/product/issues/849)
remains separate from [Command Palette #891](https://github.com/unwired-dev/product/issues/891).
[Issue #845](https://github.com/unwired-dev/product/issues/845)
owns the future conversation integration.

The implementation decision panel considered reusing the supported message
semantics (A) or expanding this issue to implement the missing thread, bulk, and
Pin infrastructure first (B). Claude Fable 5.1, GPT-6.1-Sol, and GPT-6-Astra all
selected A: preserve current action semantics, avoid duplicating existing launch
work, and disclose the limitation. The future Thread requirements above describe the
confirmed product direction; this section identifies the current integration
boundary.
