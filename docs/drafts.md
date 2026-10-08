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
  presses create one Draft. Refused navigation leaves it available to try again.
- **Drafts** are listed in the Inbox column apart from received mail, newest edit
  first. Each row is labelled `DRAFT` and names its subject, recipients and sending
  mailbox. Sender/subject search lists received mail alone; clearing the search
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

Links, inline images, attachments, the Slash Command Menu and recipient suggestions
are later slices.

## Saving

Every edit is saved as it happens, in order: an edit made while an earlier one is
being written is saved after it, never dropped. The composer shows **Saved on this
device**, **Saving…** or why the latest edit is not saved. Unsaved edits stay in
the composer and are saved by the next edit or **Try again**.

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
composer stays open and says so. Closing a Draft with no recipients, subject or
body text discards it only if no other window has completed its content. **Discard**
asks before deleting a Draft from this device.
Opening **Account**, switching to another Draft, starting **New Message**, or selecting received mail
also finishes recipient entry and waits for saving; invalid entry or a save failure
keeps the current composer open. A failed discard keeps the Draft visible and can
be retried. A concurrent save from another storage writer is recovered once;
closing an empty stale composer preserves that writer's completed Draft and
finishes with **Saved on this device**. Edits accepted while discard was pending stay available for saving and
reopening. An unexpected failure while leaving keeps the composer open and allows
another attempt. Drafts and received mail share the Inbox column's scroll surface.
After an interruption or relaunch the Drafts list shows every saved Draft, and
opening one restores its sending mailbox, recipients, subject and formatted body
without sending it.

## Storage and isolation

Drafts are stored in the [private Inbox storage](private-inbox-storage.md#draft-storage)
as one encrypted document for the signed-in Product Account. Another Product
Account on the device never reads them: signing out, deleting the account or this
device's removal purges them, and a different account starts with none. Storage
needs no Gmail access, so Drafts open offline. Locked storage shows **Drafts are
locked** with **Try again**. Logs carry no Draft content.

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
conflict copy. Component regressions exercise repeated Undo and Redo before a
render, including durable Close and reopen.
They also cover clean stale discard, empty-only recovery's final saving status,
deletion-target rebinding during recovery, and bounded retry failures. Batched
host events verify caret movement, typing-mark changes and Undo immediately
followed by text editing; these remain component integration evidence.
Host regressions also cover repeated New Message presses during a held save.
Mobile deletion regressions use the post-edit caret to preserve the remaining
character's marks with or without a key event; they do not qualify native keyboard,
dictation, autocorrection or IME behavior.

Deferred before release: native iPhone, iPad and Mac journeys that compose, relaunch
and reopen a Draft; VoiceOver, hardware-keyboard and Dynamic Type qualification of
the composer; and physical-device lock behavior.
