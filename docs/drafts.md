# Local rich-text Drafts

Setup, coding rules, validation and observable requirements remain in this file.

[#611](https://github.com/unwired-dev/product/issues/611) adds product-authored
**Drafts** to the connected Gmail Inbox on iPhone, iPad and Mac. A Draft is an
unsent message kept encrypted on this device until it is discarded. This slice
adds no delivery: nothing is sent, queued in an **Outbox** or written to Gmail's
Drafts mailbox, and Drafts do not synchronize to other devices yet.

## Composing

- **New Message** in the Inbox column starts a Draft from the mailbox the Inbox
  shows, or the first usable mailbox under **All inboxes**. It opens the composer in
  the detail column: a route of its own on iPhone, beside the Inbox on iPad, and in
  place of the reader in a Mac window. Each Mac window has one composer.
  While starting that Draft is pending, **New Message** is disabled; repeated
  presses create one Draft. If its mailbox stops being able to send, or the Product
  Account changes, while the open composer is saving, no Draft starts. Refused navigation leaves it available to try again.
  A destination chosen while creation waits stays selected. An abandoned empty
  Draft disappears from the list immediately; when storage refuses saving, the
  next successful save makes its removal durable. Selecting the new Draft's row
  or another editor adding content keeps it available.
- **Drafts** are listed in the Inbox column apart from received mail, newest edit
  first. Each row is labelled `DRAFT` and names its subject, recipients and sending
  mailbox. A **From** line always shows the sending address, followed by a
  one-line excerpt from the start of the body when its plain-text form is nonempty.
  Block breaks become spaces, including empty blocks; whitespace is preserved.
  The subject, recipient summary, From address and body excerpt show bounded
  prefixes; a long body or recipient list does not need to be read in full to
  show its row. A prefix may end before the row's right edge, depending on
  the characters and available width. The accessible row name says **Preview
  shortened** when metadata is cut. Recipient names (or addresses when
  unnamed) are grouped under **To**,
  **Cc** and **Bcc**, separated by `·`; empty groups are omitted and an empty
  recipient list says **No recipients**. The accessible row name keeps those same
  roles within the preview; later recipients or groups may fall beyond its end.
  Bcc names appear in the sender's Draft list, including a Bcc-only Draft, within
  that same bound. The composer retains the full subject and recipients for
  editing; its title and From choices also use bounded previews and announce
  shortening. Sender/subject search lists received mail alone; clearing the search
  restores the Draft rows. Selecting one opens it directly for editing; Drafts have no reader.
- **From** always shows the sending mailbox and lists every mailbox that can send.
  A mailbox waiting for Gmail authorization cannot be chosen. If the Draft's mailbox
  needs authorization again or is removed from the account, the Draft keeps it and
  explains why it cannot send; another mailbox is used only after the person chooses
  it. Nothing substitutes a sender silently.
- **To**, and **Cc** and **Bcc** after **Cc/Bcc**, accept `Name <address>`,
  `"Last, First" <address>` or a bare address. A comma, semicolon, Return or leaving
  the field turns finished entries into removable recipients. Text that is not a
  valid address stays in the field with **Enter a valid email address.** An address
  already in To, Cc or Bcc is not added again and shows **Already added**. Once Cc
  or Bcc is shown or holds a recipient, both stay shown for that Draft.
  Text still being typed in a recipient field is saved with the Draft, so an
  interruption or relaunch restores it in that field.
- The body edits a **Semantic Message Document**: paragraphs, headings one to
  three, bulleted and numbered lists, quotes and code blocks, with bold, italic,
  underline, strikethrough and inline code. The formatting toolbar applies marks to
  the selection, or to the next typed text at the caret, and sets the block kind of
  every selected block. Moving the caret ends marks toggled for typing, including
  when text is entered before the composer redraws. Typing `# `, `## `, `### `, `- `, `* `, `1. ` or `> `, or
  three backticks, at the start of a paragraph applies that block kind and removes
  the marker; one **Undo** restores the literal marker. Return continues a list,
  quote or code block, and deleting into a list marker turns the item into a
  paragraph. List markers are shown, never stored. On Mac, Command-B, Command-I and
  Command-U format the selection.
- **Undo** and **Redo** step through the composer's edits, a word of typing at a
  time; on Mac, Command-Z and Shift-Command-Z do the same in the body.
  Each activation moves one step, including repeated commands before the
  composer redraws.

Links, the Slash Command Menu and recipient suggestions are later slices.

## Saving

Every edit is saved as it happens, in order: an edit made while an earlier one is
being written is saved after it, never dropped. The composer shows **Saved on this
device**, **Saving…** or why the latest edit is not saved. Unsaved edits stay in
the composer and are saved by the next edit or **Try again**.
An editor whose content is unchanged creates no conflict copy when another editor
has saved newer content; any earlier unsaved work still finishes saving.

Conflicting edits from separate Mac windows or storage writers are preserved as
separate Drafts labelled **DRAFT · CONFLICT**. Independent Drafts survive a
concurrent save. The newer stored version keeps its identity; the stale editor
follows its own conflicting copy, including its Undo and Redo history. Further
edits, Close and Discard affect that editor's version. An edit racing a deletion
survives as a conflicting copy while the deleted identity stays removed. Review a
conflicting copy and discard it explicitly when it is no longer needed.
This also applies to authored edits arriving after an empty Draft was closed;
an empty late edit creates no copy. A completed explicit discard suppresses
later events from the editor that discarded it.

**Close** first turns any address still being typed into a recipient; text that
is not a valid address keeps the composer open until it is corrected or removed.
It then saves and closes only once the Draft is stored; when that fails the
composer stays open and says so. The compact iPhone system **Back**, Mac window
close and Mac **Quit** currently have the separate native limitations below.
Closing a Draft with no recipients, subject,
body content or attachments discards it only if no other window has completed its content. **Discard**
asks before deleting a Draft from this device.
If another window or storage writer edited the same Draft since it was opened, a stale
Discard preserves that writer's completed version in the Drafts list.
Opening **Account**, switching to another Draft, starting **New Message**, or selecting received mail
also finishes recipient entry and waits for saving; invalid entry or a save failure
keeps the current composer open. A failed discard keeps the Draft visible and can
be retried. A concurrent save from another storage writer is recovered once;
closing an empty stale composer preserves that writer's completed Draft and
finishes with **Saved on this device**. Edits accepted while discard was pending stay available for saving and
reopening. When a pending save moved the editor to a conflict copy, edits accepted
while a failed discard waited save into that same copy without an extra conflict
Draft. An unexpected failure while leaving keeps the composer open and allows
another attempt. Drafts and received mail share the Inbox column's scroll surface.
If saving failed or private storage became locked, the Inbox also says that Draft
changes are not saved and offers **Save Drafts**. Keep the app open until saving
succeeds; unsaved changes survive in memory, not a process termination or account
removal. On iPhone, selecting the current Draft again requests its composer without trying to
leave it, so unfinished recipient text remains available to correct.
After an interruption or relaunch the Drafts list shows every saved Draft, and
opening one restores its sending mailbox, recipients, subject and formatted body
without sending it.

## Files and images

[#612](https://github.com/unwired-dev/product/issues/612) adds files and inline
images to Drafts. Each host offers its own system affordances rather than identical
controls:

- **iPhone and iPad:** **Attach File** (the Files picker), **Attach Photo** (the
  Photos picker), **Insert Image** (a photo placed inline at the caret) and
  **Paste Image** (images on the pasteboard, placed inline). The pickers copy the
  chosen files into a protected temporary folder that import completion or failure,
  an abandoned picker result, or the next launch removes.
- **Mac:** **Attach Files…** and **Insert Image…** open the system open panel.
  Files dropped anywhere on the composer are attached. Pasting an image into the
  body places it inline at the caret; pasting a file attaches it, and text pastes
  as usual. The app reads only files the person chose or dropped.
- **Received attachments:** a Downloaded Attachment in the reader offers **Attach
  to New Message**. It starts a Draft from the reader's mailbox when that mailbox
  can send, otherwise the first one that can, and copies the downloaded bytes
  through that mailbox's current generation. The Draft keeps only its copy of the
  bytes: no mailbox, generation, file name or Gmail authorization of the source.

Native Apple code accepts plain file imports only from picker-owned copies, or
on Mac from files outside the app's container that the system permits it to read.
A Downloaded Attachment must use the received-attachment source and its current
Mailbox Connection authorization; naming its plaintext path as a plain file is
refused.

An inline image is part of the formatted body, so typing around it, deleting it,
**Undo** and **Redo** keep its place and reference. The composer lists
**Attachments** and **Inline images** under the body with their name, size and a
**Remove** action; an inline image shows its picture.

An added file is **importing** until its bytes are stored. While it imports, its
row says **Adding…** and offers **Cancel**. A file whose import was cancelled,
interrupted by quitting or relaunch, could not be read or saved, or is too large
stays listed as **Not added** with the reason, and the composer warns that files
not added are not sent. Only complete files can be sent: `unsendableAssets` in
`@private-email/mail-core/drafts` lists everything else for the delivery slice.
When the composer opens, it checks every complete file's bytes against their
recorded digest; an attachment's bytes stay in native code, and only an inline
image's are returned to show. Bytes that no longer verify show as **Damaged on
this device**; bytes the device lost show as **No longer on this device**. A check
refused while private storage is locked says so and offers **Try again**; it also
runs again when the app returns to the foreground. **Attach to New Message** opens
its Draft even when storage refuses the save, so the composer shows the unsaved
state instead of leaving another hidden Draft behind. One file
may be up to 25 MiB, and all Drafts and their files share the **Outgoing Content
Store**'s 100 MB on this device; a file over either limit is refused rather than
evicting anything. One pick, paste or drop adds at most 20 files; the rest of a
larger selection is not added. A picked or pasted file over 25 MiB is listed as too large
without an app-owned staging copy; the system may first create a temporary representation.
A file whose import fails is deleted at once, even
if native code had already stored its bytes.

Editing in the composer while an import finishes neither loses the edit nor
creates a conflicting copy. An import still running when its Draft is closed
completes into the stored Draft. Closing an attachment-only Draft preserves its files.
Deleting an importing inline image and then choosing **Undo** after import finishes
restores its verified bytes. An edit racing **Discard** keeps the conflict copy's
files as well as its body. A picker result arriving after the composer closes or
the Product Account changes is discarded. Repeated **Attach to New Message**
presses start one operation; navigation chosen while its save waits stays selected.

## Storage and isolation

Drafts are stored in the [private Inbox storage](private-inbox-storage.md#draft-storage)
as one encrypted document for the signed-in Product Account. Another Product
Account on the device never reads them: signing out, deleting the account or this
device's removal purges them, and a different account starts with none. Storage
needs no Gmail access, so Drafts open offline. Locked storage shows **Drafts are
locked** with **Try again**. Logs carry no Draft content.

Native Apple code owns [that storage](private-inbox-storage.md#draft-storage):
encryption and its key, the Product Account owner and revision checks, the
**Outgoing Content Store**'s 100 MB limit and the purge. The TypeScript Draft store in `@private-email/mail-core/drafts`
owns ordered autosave, rebasing onto a newer revision and conflicting copies; it
never handles key material.

A Draft's files and inline images are stored as separate [Draft Assets](private-inbox-storage.md#draft-storage).
The Draft document records each one's name, type, state, and once complete its
size and SHA-256 digest; the bytes never enter the document. Bytes are stored
before any Draft names them as complete, and a Draft that no longer uses an asset
gives it up only after the document without it is stored. While the app runs, an
asset that a still-listed Draft has used stays stored so **Undo** can restore it;
discarding the Draft removes it, and after a relaunch the first save removes any
asset no Draft uses. If removing unused bytes fails after the document is stored,
the save still succeeds and a later save retries that cleanup.

## Verification

```sh
mise exec -- pnpm --filter @private-email/mail-core test
mise exec -- pnpm --filter @private-email/mobile test
mise exec -- pnpm --filter @private-email/macos test
mise exec -- zsh native/private-inbox/integration/test.zsh ios
```

The shared tests cover block and mark editing, Markdown markers and their Undo
step, word-at-a-time history, recipient parsing, invalid and duplicate addresses,
ordered autosave while a save is in flight, failure and retry, locked storage,
relaunch, a removed or unauthorized sending mailbox, and Product Account isolation,
including an edit started before an account change. They use
`@private-email/mail-core/testing/drafts`, which follows the native owner and
revision rules without encryption.
The mobile and Mac component journeys create a Draft, enter recipients, format and
undo, autosave, finish or refuse unfinished recipient text on Close, reopen the
Draft after a remount, keep a Draft open while saving fails,
and choose another sender after its mailbox is removed; the Mac journey also uses
the keyboard shortcuts. These are rendered component tests, not native E2E.
Feedback regressions also reject a New Message identifier after account
invalidation and recover failed or locked saves from the Inbox without a mounted
composer, then reopen the content through a fresh Draft store. The mobile journey
checks that selecting the current Draft dispatches its reveal action even with
invalid recipient text and a failed save; this does not prove native column
visibility.
Shared regressions preserve late authored edits and concurrent storage edits
after abandoning an empty New Message. Both host journeys keep a later destination
selected through locked creation and cleanup, then use **Save Drafts** and reopen
the store to verify that the abandoned blank Draft was not saved.

The hosted iOS 27 storage suite checks the Draft document with the real
filesystem, CryptoKit and Simulator Keychain: ciphertext without its plaintext,
reopening from another store instance, refusal for another account or a stale
revision, the 100 MB limit, preserved damaged ciphertext and removal by an account
purge, and refusal to replace a missing encryption key while a mailbox remains.
Shared regressions cover conflicting window edits, concurrent storage writers,
failed deletion, and edits within repeated text with different formatting. Component
journeys also cover Undo between subject and body, blocked switching and discard
failure recovery. Combined search/composer journeys cover hidden Draft rows,
search empty state and saved-body labels, refusal to select a result with invalid
recipients or unsaved edits, and durable recovery before switching to received mail.
Conflict journeys follow the selected copy through Undo, Redo, continued typing
before a render, and Discard. Cross-field callbacks and recipient completion
before a render preserve the latest authored fields through Close and relaunch.
Storage regressions cover copy-identifier collisions
between writers and rebinding after failed saving and Retry.
They also cover Discard queued behind an autosave that moves its editor to a
conflict copy, including failed deletion after a late edit, with exactly the other
writer's version and the edited copy retained after reopening storage. Component regressions exercise repeated Undo and Redo before a
render, including durable Close and reopen.
They also cover clean stale discard, empty-only recovery's final saving status,
deletion-target rebinding during recovery, and bounded retry failures. Batched
host events verify caret movement, typing-mark changes and Undo immediately
followed by text editing; these remain component integration evidence.
Host regressions also cover repeated New Message presses during a held save and
visible and accessible recipient roles in Bcc-only and mixed-role Draft rows,
including a visible From address alongside a non-empty body preview.
The shared preview regression preserves empty-block spacing and whitespace,
avoids splitting an emoji at the excerpt boundary, and verifies that later body
spans are not read after the bounded excerpt is complete.
Metadata regressions stop reading recipients once the row prefix is complete,
preserve short recipient-role summaries, and check both hosts' bounded row names,
From choices and composer titles while full authored values remain saved.
The emptiness check stops at the first non-whitespace body span without joining
the body; whitespace-only content keeps the same Close behavior.
They also cover later destinations and selecting the new Draft's row while
creation is pending, preserving content added to an abandoned Draft, and a
successful Discard queued behind autosave with a late native text callback.
Mobile deletion regressions use the post-edit caret to preserve the remaining
character's marks with or without a key event; they do not qualify native keyboard,
dictation, autocorrection or IME behavior.

Asset coverage (#612): shared store tests insert, delete, round-trip and Undo an
inline image; store verified bytes through relaunch, Undo and Draft deletion;
keep cancelled, failed and interrupted imports unsendable while their stray bytes
are removed; refuse files over the limits; read damaged or missing bytes as
unavailable; and copy a received attachment without its mailbox, for its Product
Account only. Both hosts' component journeys attach files and an inline image
through the pickers, cancel an import, edit while an import completes without a
conflict copy, show an interrupted import and the stored files after relaunch,
show damaged image bytes, remove and restore an inline image with **Undo**, and
attach a Downloaded Attachment from the reader. The Mac journey also pastes an
image and drops a file. These use the synthetic Draft storage and remain component
evidence. The hosted iOS 27 storage suite seals assets to their Product Account
and identifier, verifies their digest, rejects moved ciphertext and other
accounts, keeps an uncommitted import through a save that does not name it,
removes unused assets after a stored document, imports pasted data and a current
Downloaded Attachment, refuses an oversized file before reading it, and purges
assets with the account. Review regressions also cover attachment-only Close and
relaunch, deleting an importing image before settlement and restoring it with
**Undo**, a concurrent Discard that preserves a conflict copy's asset bytes, picker
results arriving after Close or account replacement, and navigation during a
received-attachment save. Native checks remove owned picker copies on rejected
imports and preserve similarly named directories containing user files.

Deferred before release: native iPhone, iPad and Mac journeys that compose, relaunch
and reopen a Draft; the system Photos and Files pickers, the Mac open panel,
pasteboard images, Mac drag and drop and Mac sandbox file grants with real files;
how the body shows an inline image's place in its text on each platform; VoiceOver, hardware-keyboard and Dynamic Type qualification of
the composer (including Draft row role labels and middle-dot separators at
different VoiceOver punctuation settings); and physical-device lock behavior.

Known native gap, deferred before release: compact iPhone system **Back** can hide
a composer without first validating recipient entry or saving its changes. The
Inbox warning
and **Save Drafts** action mitigate a failed or locked save, but do not prevent
Back or make unsaved edits durable. Add and qualify native transition protection
before release, covering the Back button and swipe, pending/failed/locked saves,
unfinished recipients, selecting the same Draft to reveal it again, and successful
retry.

Mac window close and **Quit** also bypass the composer's leave guard. Closing a
window keeps unsaved changes in memory while the app runs, even after its last
window closes. A pending autosave can still finish; if saving fails or storage is
locked, every Inbox window, including a reopened one, shows the warning and
**Save Drafts**. Unfinished recipient text is included when the Draft is saved.
Closed composers stop following later conflict copies, while their unsaved edits
remain available to **Save Drafts**. A confirmed Discard already waiting for a save
still finishes against its own conflicting version after the window closes.
Quitting before the latest changes are stored loses them, including while a save
is pending, failed or locked. The warning and retry do not prevent close or Quit.
Add and qualify native close and quit protection before release, covering
unfinished recipients, pending/failed/locked saves, multiple windows, closing the
last window, and successful retry. These native exit gaps are tracked in
[#778](https://github.com/unwired-dev/product/issues/778). The component tests do not
satisfy these native checks.
