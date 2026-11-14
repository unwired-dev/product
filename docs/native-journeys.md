# Native journeys

These entries describe what each native E2E journey exercises.

## Mac performance journey

On the Mac, the `testWarmCachePerformance` journey measures the
[performance budgets](agents/native-validation.md#performance-qualification)
except Mail View switching, which remains deferred. It measures typing, formatting
shortcut and format bar feedback from the input to the text-storage update and
the display frame that draws it, as described below. Build the `Testing`
configuration, which
is Release-optimized with packaged JavaScript plus the test-only probes, with
`UNWIRED_MOCK_SCENARIO=registration-performance`, then run it with the
[Mac runner](mock-mail-sessions.md#native-mac-entry-point):

```sh
UNWIRED_MOCK_SCENARIO=registration-performance \
mise exec -- pnpm --filter @private-email/macos native:build Testing
mise exec -- pnpm --filter @private-email/macos test:native \
  "$PWD/artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app" \
  testWarmCachePerformance
```

The journey signs in with Apple and connects the synthetic Microsoft and Gmail
mailboxes, 126 and 128 Inbox Threads. It opens five messages of each once so
their bodies are cached, then measures 10 relaunches until the unified Inbox
lists, 21 switches between both Inboxes and All inboxes, 10 body openings per
mailbox and 10 openings each of an empty composer and a saved Draft. Each
composer sample ends with the composer's Close in the same process, which also
covers the close-and-reopen crash fixed in
[#1174](https://github.com/unwired-dev/product/issues/1174). In a new message it then
types 20 characters into the body, turns bold on at the caret with Command-B and
types 11 bold characters, then selects the last word and presses Command-B, B,
I, I, U, U twice, so each mark toggles on that word and back. It then clicks the
format bar's Bold, Bold, Italic, Italic, Underline and Underline buttons twice
over on the same word. Finally it presses Right to collapse the selection, then
Command-B, and types 4 characters that must be unmarked while the word stays bold.
The synthetic relay
records each provider body request in the probe evidence; the journey fails if a
cached-body sample requested one, or if priming recorded none.

A click sample runs from the mouse release, recorded by the app on the same
uptime clock, until an accessibility query finds the rendered result. A launch
sample runs from the launch request. Click and launch samples include XCUITest's event
completion and queries, about 35–45 ms each, so it is an upper bound: a sample
within budget passes, but an overrun only shows that the budget is not proven.
The app records main-queue probe delays of 100 ms or longer; the report names
stalls overlapping sample windows and in the whole session. Missing or malformed
probe evidence, including a click sample without its mouse events, fails the journey.

A key sample runs from the key press the app records to the first edit of the
focused body's text storage that begins with the expected text and the bold,
italic and underline marks of each of its characters, so a later key press
cannot hide a late result. A format bar sample runs the same way from the mouse
release the app records. Both times come from the app, so these samples exclude
XCUITest. It compares that duration to `1000 / maximumFramesPerSecond`
of the key window's display, the interval at the display's maximum supported refresh
rate. The edit notification fires before layout managers receive the change, so a
key or format bar group's `withinBudget` result describes only the text-storage update.

Next-rendered-frame feedback comes from the body's first draw after that edit. The
body's latest edit before that draw must still show the expected text and marks;
a result that a later input replaced before any draw fails the journey. A
display link records display frame starts on the same clock. The journey places
the end of that draw in the frame that started last before it, counting frames from any recorded
start at the link's frame interval, and reports `framesLate`: the frames that
started after the input and before that one. `nextRenderedFrame` holds when the
group's p95 is 0. This is a group percentile criterion; individual late samples
remain in `framesLate`. `drawnMs` runs from the input to the end of the draw.
Keep the journey window on one display, refreshing at a constant interval while
the journey types. The probe ends at draw completion; it does not observe
window-server compositing or display presentation. The probe's synchronous
key-event logging also adds work before the edit. A key press, button release
or expected edit missing from the evidence fails the journey.
The probe samples every 10 ms after its launch setup. No recorded delay means no
observed stall; it does not prove the absolute stall cap for every main-thread
task or for startup before the probe begins.

The journey writes one `PERFORMANCE` JSON line per interaction to
`xcodebuild.log` and the same lines as an XCTest attachment. Each line has the
samples, p50, p95, maximum, budget and stalls. The final line has the
query overhead, the synthetic press duration and every session stall. It
measures neither Mail View switching, keyboard or accessibility journeys, nor the
iPhone and iPad references.

## Mac keyboard and accessibility journey

The `testKeyboardAndAccessibility` journey uses the same `registration-performance`
`Testing` build and sign-in as the [performance journey](#mac-performance-journey);
the journey requires that scenario:

```sh
UNWIRED_MOCK_SCENARIO=registration-performance \
mise exec -- pnpm --filter @private-email/macos native:build Testing
mise exec -- pnpm --filter @private-email/macos test:native \
  "$PWD/artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app" \
  testKeyboardAndAccessibility
```

Pass `testKeyboardAndAccessibilityDark` instead to run it in Dark appearance.

By keyboard, it runs Search Mail from the Command Palette and types a query. It
then cuts and pastes that query through the Edit menu. It closes the palette with
Escape and checks that focus returns to the search field. It moves through the
palette's commands with Down and Up and runs Search Mail with Return, checking
focus returns to search and Settings stays closed. It then runs Account from the
palette, which opens Settings. In Privacy & Data it clicks the device's remote-content
pop-up, dismisses its AppKit menu with Escape, then chooses Never from it and checks that
the pop-up shows the choice. In Language it checks that the interface-language pop-up shows
System Default. In Mail Profiles it adds a **Travel** Mail Profile, checks its Color and
Icon pop-ups show Graphite and First Letter, and chooses Blue and Airplane from their AppKit
menus. It then asks to remove the Mail Profile:
the AppKit sheet on Settings offers Cancel and Remove and closes with Escape and with
Return, its default Cancel, keeping the Mail Profile; Remove then removes it. It closes
Settings with Command-W. It then opens the Gmail
message **Garden plans for spring** with the pointer and clicks each link's keyboard control.
Each link's AppKit alert sheet shows its title and full destination. Command-P stays closed
behind the sheet, and Escape and Cancel close it. The flagged link's sheet closes with Escape
and with Return, its default Cancel. The journey never opens or copies a link. Afterwards
Command-P opens the palette again. It then searches for the
Microsoft message **Quarterly planning** and opens it. The reader's **Folders** AppKit
menu closes with Escape and with a click outside, then Down and Return choose
**Projects**, which moves the message and closes its reader. Before continuing, it
checks the moved-message notice and rejects refusal, unsaved, pending and unfinished
save/sync states. This is a synthetic completion proxy, not provider destination
readback. It runs Reply from the palette,
types into the reply and pastes into it. It then selects the reply and clicks
**Add Link** ([#1792](https://github.com/unwired-dev/product/issues/1792)): the
Link Editor popover opens with the selection as its Text, Link focused and empty,
Apply disabled and no Remove Link. Its audit completes with two exceptions: the
tracked contrast gap [#1794](https://github.com/unwired-dev/product/issues/1794)
and the hint's false "Label duplicates role description" finding. The capture is
kept as an `Add Link` attachment. Review it for the body's selection drawn as inactive
([#1796](https://github.com/unwired-dev/product/issues/1796)); no assertion checks the highlight. An invalid destination shows its reason after Return,
Escape closes the popover keeping the text and selection, which reopening it
prefills again, and a valid destination applied from it reads **Edit Link**, which one Undo reverts and Redo restores.
Edit Link then offers Remove Link with the saved destination, and Escape closes
it. With the reply docked, it clicks the
reader toolbar above it ([#1211](https://github.com/unwired-dev/product/issues/1211)):
**Folders** opens its menu, which Escape closes, and the read toggle flips while the
reply keeps its text. After relaunch, it checks that the
saved Draft reopens with that text, and Edit Link with its saved destination.
With Mail Assistance turned on in Privacy & Data, **Rewrite the message body** from
Writing tools ([#1898](https://github.com/unwired-dev/product/issues/1898)) shows the
synthetic rewrite with the kept link note and **Replace text** in the accent tint.
Return adds a new line to the focused body, which closes the result, and
Undo removes it; Replace text on a new rewrite makes the body the rewrite, and one
Undo restores the reply. After " at 9:30" is typed, the
rewrite reports one differing detail with its row and **Use rewrite with changes**;
the count line is one text element between the rewrite and the row
([#1902](https://github.com/unwired-dev/product/issues/1902)),
and Keep original closes it with the reply unchanged. Both states are audited and
kept as `Writing tools W1` and `Writing tools W2` attachments. Command-N opens a second Inbox with no
selection; Command-backtick, Command-0 and Command-W then move between and close
windows while the first window keeps its Draft. Expand then moves that saved
Draft into a New Message window, removes the overlay and omits Expand there.
In that window, Send sits level with the window controls, and clicking the
Command Palette input there opens the palette.
When the palette first opens in the Inbox, and again in that window, the
journey compares window captures taken before and after opening it across the
panel's first rows and fails if too few points change, so a palette that only
exists for assistive technology fails
([#1573](https://github.com/unwired-dev/product/issues/1573)). Each open-palette
capture is kept as a `Command Palette open` attachment.
Unfinished recipient text keeps that window open after Command-W and cancels
Quit. Clearing it permits Command-W and the Inbox retains the Draft. Reopening
that Draft and expanding again permits Quit from the new guarded window, stopping
the app. This checks the regular editor's recipient guard
and successful save/close; failed or locked native saves and multiple guarded
windows remain deferred. Opening a message, placing the
caret in the new reply and Send still use the pointer (see
[#849](https://github.com/unwired-dev/product/issues/849)). The journey never
sends. Cut and Copy use
the desktop pasteboard. The journey restores its earlier contents only if
nothing has written to it since the journey's last Cut or Copy.

It runs XCTest's accessibility audit on the Inbox, Command Palette, Settings,
Privacy & Data, Language, the flagged link's sheet over the HTML reader, reader,
composer and Link Editor, and prints each issue as an `ACCESSIBILITY` JSON line
in `xcodebuild.log`. `knownAccessibilityGap` names the owner of each issue the
audits still report. These are the Link Editor hint on popover glass ([#1794](https://github.com/unwired-dev/product/issues/1794)),
labels the contrast audit flags although their captured pixels pass, that
fail only while another window or an AppKit sheet dims their window, or that sit
on the Command Palette's glass panel
([#1550](https://github.com/unwired-dev/product/issues/1550)),
AppKit's text Touch Bar, email or web addresses used as labels, Private Cloud's
row while Mail Assistance is off (an inactive control), and the false "Label
duplicates role description" finding on the Link Editor hint, Private Cloud's
explanation and the Writing tools privacy note, sentences containing "text". The contrast gaps list
the labels each owner covers in either appearance. Any other issue fails
the journey; remove a gap once its owner fixes it. The AppKit Touch Bar's unlocated
`Parent/Child mismatch` exception covers only the Command Palette, reader and
composer audits observed on the Mac host, while a text input has keyboard focus. Retain each run's xcresult captures
with its log when investigating that exception. The journey launches the app in Light
appearance whatever the desktop's; `testKeyboardAndAccessibilityDark` runs the same
journey in Dark. Increase Contrast is not audited. The audits do not replace VoiceOver,
Full Keyboard Access or the [iPhone and iPad journey](#iphone-and-ipad-keyboard-and-accessibility-journey).

## Mac Mail Profile isolation journey

The `testMailProfileIsolation` journey uses the same `registration-performance`
`Testing` build and sign-in as the [performance journey](#mac-performance-journey)
([#1901](https://github.com/unwired-dev/product/issues/1901)):

```sh
mise exec -- pnpm --filter @private-email/macos test:native \
  "$PWD/artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app" \
  testMailProfileIsolation
```

In Settings › Mail Profiles it adds a **Work** Mail Profile and moves the Microsoft
mailbox into it from the Primary Profile. A second window switches to Work through
its Profile Switcher. The journey tiles the two windows side by side, each on its
own half of the screen, and checks they do not overlap; it skips on a display
narrower than 1560 points, where two windows cannot fit. Each lists its own
mailbox and an `update` message but not the other mailbox or its `update` messages;
other messages are not checked. Search for `update 003` in each finds only its own mailbox's message.
A Draft saved from Work's window appears there and not in the Primary Profile's.
A message sent from Work's window waits in its **Outbox** as `Sending soon` during
the Undo Send Window while the Primary Profile's window shows no Outbox, and
Work's Outbox empties once delivery takes it
([#1909](https://github.com/unwired-dev/product/issues/1909)).
Moving the mailbox back restores its messages and the Draft to the Primary Profile
window. Each window's capture is kept as an attachment. Links are not covered.

`testMailProfileWithoutMailboxes` adds Work the same way and switches the only
window to it while it owns no mailbox
([#1538](https://github.com/unwired-dev/product/issues/1538)). The heading reads
`All Inboxes. No mailboxes`, the list shows **No Mailboxes** with its message and
no mailbox is listed. The window's capture is kept as an attachment and the
accessibility audit runs on it. **Manage Mail Profiles…** opens Settings › Mail
Profiles. It sets Light; `testMailProfileWithoutMailboxesDark` runs it in Dark.

`testBlockSender` uses the same build and sign-in
([#2141](https://github.com/unwired-dev/product/issues/2141)). It opens Gmail
update 001 and chooses **Block Sender…** from its sender's menu; the sheet asks
`Block sender001@example.invalid?` and **Block Sender** confirms it. Settings ›
Blocked Senders then lists the address as `0 since`, and selecting it and choosing
− leaves **No Blocked Senders**. The sheet and both Settings states are kept as
attachments. It sets Light; `testBlockSenderDark` runs it in Dark.

## Mac IMAP Spam and Trash folder journey

The `testImapSpamAndTrashFolders` journey and its `Dark` variant use the same
`registration-performance` `Testing` build and sign-in as the
[performance journey](#mac-performance-journey)
([#1923](https://github.com/unwired-dev/product/issues/1923)):

```sh
mise exec -- pnpm --filter @private-email/macos test:native \
  "$PWD/artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app" \
  testImapSpamAndTrashFolders
```

Settings › Email Accounts connects the
[synthetic IMAP server](mock-mail-sessions.md), which marks no Spam or Trash folder,
and lists it under Spam and Trash Folders as not chosen. All Mail shows the
[not-included notice](imap-mailboxes.md) and leaves out its Inbox message. Choose
Folders… opens the sheet with nothing chosen and Save disabled; Escape cancels it. Choosing
Bulk Mail and Deleted Messages and pressing Return saves them. All Mail then lists the
Inbox message but not Spam's or Trash's. Settings names both folders, and Change…
opens them pre-filled; Escape keeps them. Both sheets pass an accessibility audit. Each
step's capture is kept as an attachment. VoiceOver speech is not covered.

## iPhone and iPad IMAP Spam and Trash folder journey

The Expo native journey for a `registration-imap-folders` Release build signs in
with Apple, connects the Gmail mailbox and confirms the Recovery Key
([#1928](https://github.com/unwired-dev/product/issues/1928)). Build it as in
[Mock Mail Sessions](mock-mail-sessions.md) with
`UNWIRED_MOCK_SCENARIO=registration-imap-folders` and run it once per appearance:

```sh
UNWIRED_APPEARANCE=light mise exec -- pnpm --filter @private-email/mobile test:native \
  "$PWD/artifacts/mock-mail/DerivedData/Build/Products/Release-iphonesimulator/UnwiredMail.app"
```

Run it again with `UNWIRED_APPEARANCE=dark`. Without a device type the runner runs iPhone 18 Pro
and then iPad Pro 11-inch (M5); pass one, such as
`com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB`, after the app to run a single
device.

It then checks the steps of the [Mac journey](#mac-imap-spam-and-trash-folder-journey)
on iPhone and iPad, with these differences. Settings names the connection's folders
as the iPhone row's value and as the iPad row's summary beside its button. Close
dismisses the sheet and Save saves it; the iPhone row opens the sheet from Settings,
the iPad row's Change… button does. Each step's capture is named with the
appearance, for comparison with the approved frames. VoiceOver speech is not covered.

Settings › Signatures then lists the IMAP Sending Identity with None
([#2059](https://github.com/unwired-dev/product/issues/2059)). Its signature is typed,
made bold and stored when the editor is left; the row shows its first line, Delete
clears it, and the list passes an accessibility audit.

## iPhone and iPad Apple registration journey

The Expo native journey for a `registration-apple` Release build signs in with
Apple and connects the synthetic Microsoft and Gmail mailboxes; its steps are listed
under [Expo setup](expo-client.md#validate). Build it with
`UNWIRED_MOCK_SCENARIO=registration-apple` and, from the repository root, run it once
per appearance and device:

```sh
UNWIRED_APPEARANCE=light mise exec -- pnpm --filter @private-email/mobile test:native \
  "$PWD/artifacts/expo-bootstrap/DerivedData/Build/Products/Release-iphonesimulator/UnwiredMail.app" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro
```

Before the Work Profile's new message is sent, a long press on Send opens the Send
menu, **Remind Me to Send…** sets **Tomorrow Morning** from the iPhone sheet or with
the iPad popover's **Set Reminder**, and the composer stays open with the Draft's
banner, **Change** and **Remove Reminder**
([#2144](https://github.com/unwired-dev/product/issues/2144)). The captures are
named "Send menu", "Remind Me to Send sheet" or "popover" and "Draft with a Send
Reminder". The journey fails later on iPhone
([#2146](https://github.com/unwired-dev/product/issues/2146)) and iPad
([#2148](https://github.com/unwired-dev/product/issues/2148)).

## iPhone and iPad keyboard and accessibility journey

The Expo native journey for a `registration-performance` Release build drives
the same loop with hardware key presses on iPhone and iPad. Build it with
`UNWIRED_MOCK_SCENARIO=registration-performance` as in the
[mobile entry point](mock-mail-sessions.md#mobile-entry-point), then run it
on the built app:

```sh
mise exec -- pnpm --filter @private-email/mobile test:native \
  "$PWD/artifacts/mock-mail/DerivedData/Build/Products/Release-iphonesimulator/UnwiredMail.app"
```

Add `UNWIRED_APPEARANCE=light` to audit Light; the runner's default is Dark.

On the iOS 27 simulator, XCUITest's `typeKey(.escape, modifierFlags: [])` never reaches
the app, while letters and Command shortcuts do. UIKit delivers Command-period as Escape
to key commands, so journeys press Command-period to check Escape, as the Inbox
journey does for the iPad Filters popover (#1396).

The journey signs in with Apple and connects the synthetic Microsoft mailbox.
On iPhone it then drags the Inbox up 200pt and checks that the first row follows
the finger, scrolls further, and checks that the navigation title and the floating
bar keep their frames, attaching a screenshot of each state.
Each Command Palette command is typed and run with Return: Account opens Settings,
Inbox leaves it, and Search Mail focuses search. It types a query into search,
then selects, cuts and pastes it back with Command-A, Command-X and Command-V,
and Return submits it. Reply from the palette opens a Draft. Typing extends its
subject, Tab moves focus to its recipients, and the body takes typing.
Shift-Option-Left selects the reply's last word for the Link Editor, opened from
iPad's format bar as a popover and from iPhone's Format panel as a sheet. It
opens as Add Link with Text from the selection and Link focused and empty, shows
the invalid-link reason after Return, and leaves the body and selection as they
were when dismissed. A valid destination applied with Return makes the control
Edit Link, which offers Remove Link; one Undo removes the link and keeps the
text, and Redo restores it. After relaunch, the Inbox lists the saved Draft,
which reopens with both edits and the link's destination.

These steps still use touch on iPhone and iPad:

- Opening the palette, by the header swipe or the iPad command input. iOS
  offers no Command-P without native key commands.
- Opening a row.
- Placing the caret in the reply. Reply focuses no field, and Tab does not
  reach one from there, and placing it again in the reopened Draft.
- The Format panel and format bar controls, including Add Link, Edit Link,
  Undo and Redo, and dismissing the Link Editor.
- Closing the palette. A hardware Escape leaves it open.

These gaps belong to [#849](https://github.com/unwired-dev/product/issues/849).

It runs XCTest's accessibility audit on the Inbox, Mailboxes, Command Palette,
Settings, reader, composer and Link Editor, and prints each issue as an `ACCESSIBILITY` JSON
line in the test log, with a screenshot of each audited screen.
The audit handler permits these known findings:

- the software keyboard's suggestion cells;
- an email address used as a label: a sender's, or the Apple relay address
  that names the signed-in account;
- the reader's sender monogram, whose initials repeat the sender name beside it
  and for which the handler permits at most one unlocated-text finding;
- the contrast of a disabled button, which WCAG does not require, such as the
  iPad Link Editor's Apply before a link is entered;
- unlocated text while an iPad popover is open, such as the Link Editor,
  Filters or Sync Status details: the popover hides the window behind it from
  accessibility, and the audit reports the text it still sees there, such as
  the Mailboxes sidebar's rows. A plain UIKit split view behind a SwiftUI
  popover does the same (#1403).

Other findings fail the journey. On iPad the composer and its Link Editor are
audited expanded:
floating, it leaves the message visible behind it as a backdrop hidden from
accessibility and touch, which the audit reports as text it cannot locate.
CI does not run this scenario; it is local native evidence.
It does not replace VoiceOver, Full Keyboard Access or the
owner's physical-device runs. On iPad, XCUITest sometimes waits 60 seconds per
step for the app to settle while the software keyboard is shown, so a run can
take an hour; the iPhone run takes about two minutes.

## Reference device history

The iPhone reference, the owner's physical iPhone 17 Pro Max on iOS 27, was
nominated in [#1106](https://github.com/unwired-dev/product/issues/1106) on
2026-10-21. Evidence from the former iPhone 17 reference does not qualify its
replacement; [ADR 0018](adr/0018-local-mail-performance-budget.md) records that
decision. Qualification uses the available physical iPhone, iPad and Mac;
standard non-Pro iPhone access is not required. This qualification scope does
not change product hardware support.

The iPad reference, the owner's physical iPad Pro 13-inch with Apple M4
(`iPad16,5`), was nominated in
[#1105](https://github.com/unwired-dev/product/issues/1105) on 2026-10-21. At
nomination it ran iPadOS 27.0.1 (24A446). Its RAM and storage capacity were not
exposed by the host tooling.
