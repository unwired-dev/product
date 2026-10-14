# Command Palette

Setup, coding rules, validation and observable requirements remain in this file.

[#891](https://github.com/unwired-dev/product/issues/891) adds the confirmed
**Command Palette** to the maintained Mac, iPhone and iPad clients: a place to
find and run actions, including navigation to app destinations, without leaving
the current screen. Email content search stays in the Inbox search field; mail
results never appear in the palette. The vocabulary lives in the
[organization glossary](domain/organization.md).

## Commands

- **Contextual commands** act on the open message, the one the reader shows.
  The reader offers the same handlers its buttons use: Reply, Reply All and
  Forward where a response can start; Mark as read or unread, Star, Archive,
  Move to Trash and Report spam as the provider allows; and **Move to…**, which
  lists the connection's folders or labels. The preview Inbox's reader offers its
  Mark as read or unread. The palette never chooses a message on its own.
- **App commands:** New Message (while a mailbox can send; on iPhone and iPad,
  search must also be closed) and Search Mail, which opens search and focuses the
  Inbox search field. On iPhone and iPad, where a reader or
  composer can cover the Inbox, Search Mail first leaves the open reader or
  composer through the same checks as closing them. Search Mail and Go To Inbox
  also bring the message list forward where Mailboxes covers it. On the Mac they
  first collapse an expanded composer, keeping its Draft open.
- **Go To:** Inbox, which leaves the reader or composer through the same
  checks as closing them, and Account, while a Product Account is signed in.
  The palette stays available on the Account page, the app's settings, where
  Inbox returns to the connected Inbox.
- Reply, Forward, Archive and Move to… stay listed and disabled with a reason
  (Select a conversation, or Not available for this message) when nothing can
  run them. While the reader is already starting a reply or forward, Reply,
  Reply All and Forward stay listed and disabled with Already opening a
  draft, as its buttons are. The palette lists only supported commands; Pin, Snooze, Flag,
  thread-wide and bulk actions arrive with their owning work, such as
  [keyboard and bulk actions #849](https://github.com/unwired-dev/product/issues/849).
- The [Thread view](catch-up.md#thread-view) opens the palette from its fixed
  subject header, but offers no message actions of its own, so its contextual
  commands stay disabled with Not available for this message. Catch Up's
  Thread actions ([#807](https://github.com/unwired-dev/product/issues/807))
  register them when they define whole-Thread targets.

## Finding and running

- With an empty query, contextual commands appear first, then App, then Go To,
  each in a fixed order. Typing narrows them: every typed word must start a word
  of the command's name or one of its common synonyms, fuzzily (`arch` finds
  Archive, `mv` finds Move to…, `folder` finds Move to…). Accents are ignored.
  Nothing is personalized by usage.
- The targets are fixed when the palette opens. Before a command runs, the
  palette checks that the same message still offers it; one whose message left
  the reader meanwhile shows No longer available instead of acting on another.
- Move to… opens its folder or label picker inside the palette; typing narrows
  it, Back (or Escape on the Mac) returns to the command list, and nothing moves
  until a destination is chosen.
- Commands use the same confirmations, Undo and error reporting as the buttons
  they stand for: an archive from the palette shows the reader's notice and Undo.
- Running a command closes the palette. Cancel, a tap or click outside, or
  Escape closes it too and hands focus back to the control that had it. On the
  Mac, AppKit keeps the window's focused control, so focus returns to an Inbox
  row or a button as well as a text field, and to the command input when it was
  focused. Each opening starts with an empty query.

## Entry points

- **Mac:** a command input stays visible in a bar at the top of each window,
  the Account page included.
  Clicking it, or choosing View › Commands… (Command-P), opens the palette
  beneath it without shifting the window's layout, with the query focused. Up and
  Down select a command and scroll it into view, Return runs it, Escape closes the palette or leaves the
  picker; the footer names these keys. The bar shows the Command-P shortcut.
  Per-command shortcuts appear only once the keyboard shortcuts of
  [#849](https://github.com/unwired-dev/product/issues/849) exist.
  While a link confirmation is open, dismiss it before opening the palette in
  that window; command entry in other windows remains available.
- **iPhone:** a downward swipe that starts on a screen header (the Inbox heading,
  the Mailboxes title, the reader's subject line, the composer's top bar or the
  Account page's title,
  which stay put while the content scrolls) opens the palette; swipes that start in the content scroll
  it as usual. There is no visible entry button. A one-time hint under the
  Inbox heading says Swipe down on the header for commands, and goes away once
  dismissed or after the palette first opens; the choice is kept in the
  device's preferences. Each header's title also exposes an Open Command
  Palette accessibility action for VoiceOver and other assistive controls. A
  reader, Thread or composer that is loading, cannot open its storage or has
  no message or Draft to show keeps the same swipe and action, on its title or
  its loading indicator, since it still covers the Inbox.
- **iPad:** the command input stays visible in the Inbox heading, the reader's
  header, the composer's top bar and the Account page's title row, and at the
  top of a reader, Thread or composer that is loading, cannot open its storage
  or has no message or Draft to show, so one is on screen in every size class,
  including compact layouts that show only the reader or composer; tapping it
  or the header swipe opens the palette. Command-P from a hardware keyboard is
  deferred: React Native exposes no key commands on iOS without a native
  module, and the Mac host owns the only keyboard entry today.
- On iPhone and iPad the palette is a panel attached to the top of the screen
  with the input focused, the software keyboard shown when needed, and the
  commands beneath; any command can be tapped without typing.
- The [Tiptap evaluation editor](draft-editor-evaluation.md), only in
  `registration-draft-editor` Mock Mail Session builds, adds no entry of its
  own; entries outside it, such as the Mac window's command bar, still open
  the palette. Production and TestFlight builds open Drafts in the current
  composer, with the entries above; if the adoption decision
  ([#823](https://github.com/unwired-dev/product/issues/823)) replaces that
  composer, that work carries them over.

## Validate

Component tests cover opening from each entry, including the Thread reader,
the fixed order, fuzzy narrowing, running Archive and Move to… on the open
message with Undo, the disabled reasons, Search Mail leaving the reader and
bringing the list forward from Mailboxes, New Message following the floating
bar's button, the Account page's entry and its way back to the Inbox, Command-P
opening the Mac palette only while its window shows the bar, an open palette leaving with its
screen when registration replaces it, Back, Escape and the Mac's outside click,
and a target that disappears after opening.
From the root:

```sh
mise exec -- pnpm --filter @private-email/mail-core exec vitest run test/commands.test.ts
mise exec -- pnpm --filter @private-email/mobile test -- test/inbox.test.tsx test/thread.test.tsx test/profile-routing.test.tsx test/composer.test.tsx
mise exec -- pnpm --filter @private-email/macos test -- test/windows.test.tsx test/registration.test.tsx test/composer.test.tsx
```

The Command-P menu item, the saved hint preference and the header swipe are
native and need a built host: the [Mac host](macos-client.md) and the
[Expo app](expo-client.md). The swipe's arbitration with the scrolling content
beneath each header, and the accessibility actions, remain to be qualified on
iPhone and iPad; on the Mac, so do clicks on the open panel's rows, which must
reach them above the outside-click layer.
