# IMAP mailboxes

Setup, coding rules, validation and observable requirements remain in this file.

[#629](https://github.com/unwired-dev/product/issues/629) connects a
**Standards-Based Mailbox Connection** over IMAP and reads its folders and messages on
iPhone, iPad and Mac. [#631](https://github.com/unwired-dev/product/issues/631) sends
through its SMTP server and files a copy in its Sent folder; a connection is complete
only once both its IMAP and SMTP logins verified. [#630](https://github.com/unwired-dev/product/issues/630)
organizes and searches IMAP mail at the server and keeps it fresh with IDLE where the
server offers it; certification against real iCloud Mail and Fastmail mailboxes is
[#632](https://github.com/unwired-dev/product/issues/632).

## First mailbox and provider choice

After Google or Apple Product Sign-In and device admission, the account page starts
no mailbox authorization on its own. **Connect your mail** offers:

- **Authorize Gmail**, which suggests the Google sign-in account, and **Choose another
  Google mailbox**;
- **Connect Microsoft mail** when this build is configured for
  [Microsoft mail](microsoft-mail.md);
- **Connect iCloud Mail**, **Connect Fastmail** and **Connect Another IMAP server**.

Choosing an IMAP provider asks for no Google or Microsoft grant. Saved Gmail and
Microsoft mailboxes that all need authorization again are still authorized again right
after sign-in; an IMAP password is only ever entered again on the account page. Once
any mailbox is connected, Settings' **Email Accounts** also offers **Add an
IMAP mailbox**.

## Endpoints and passwords

| Provider            | IMAP server           | Port    | User name                          |
| ------------------- | --------------------- | ------- | ---------------------------------- |
| iCloud Mail         | `imap.mail.me.com`    | 993     | The name part of the address       |
| Fastmail            | `imap.fastmail.com`   | 993     | The full address                   |
| Another IMAP server | Entered by the person | Entered | Entered, or the address when blank |

| Provider            | SMTP server           | Port and security                        | User name                               |
| ------------------- | --------------------- | ---------------------------------------- | --------------------------------------- |
| iCloud Mail         | `smtp.mail.me.com`    | 587, STARTTLS                            | The full address                        |
| Fastmail            | `smtp.fastmail.com`   | 465, SSL/TLS                             | The full address                        |
| Another IMAP server | Entered by the person | Entered; SSL/TLS on 465, else STARTTLS\* | Entered, or the IMAP user name if blank |

\* The form's **SSL/TLS** or **STARTTLS** choice follows the port until the person
chooses one.

iCloud Mail retries once with the full address when the server refuses the name
part, following [Apple's mail settings](https://support.apple.com/en-us/102525).
A successful retry saves that user name for later password repair. A refused full
address, an unreachable server or a TLS failure is not retried this way.

The form shows both endpoints it will contact before **Connect**. iCloud Mail and
Fastmail require an app-specific password, which signs in to both IMAP and SMTP; the
form says so. Another IMAP server's form adds an **Outgoing (SMTP)** group: server,
port, **SSL/TLS** or **STARTTLS**, and optionally an SMTP user name and password when
they differ from the incoming ones. Every connection uses **Secure Mail Transport**:
TLS 1.2 or newer and certificate verification against the system's trusted roots with
no override. IMAP uses TLS from the first byte (implicit TLS); STARTTLS and plaintext
IMAP ports are not offered. SMTP uses implicit TLS, or STARTTLS that the server must
offer before any authentication; a server that offers neither is left before any
credential is sent.

**Connect** logs in to IMAP, then to SMTP on its own, and adds or repairs the connection
only when both accept. Native code owns password custody. Passwords are supplied only
when connecting or repairing a connection; they are never returned to JavaScript or
sent to Convex, Private Sync or Google. Hosts may receive the address and reviewed
endpoints, without passwords.

A connection saved before SMTP receives only: the account page says **Receive only.
Enter the password again to set up sending.**, and it cannot be chosen as a sender.
Entering its password again shows its provider's SMTP endpoint, or an empty
**Outgoing (SMTP)** group for another server, and verifies SMTP before sending is set up.

The connection is identified by its endpoint and user name, so connecting the same
account again repairs it with the new password instead of adding a second one. Its
synchronized Private Sync descriptor names provider `imap` and the address; other
Trusted Devices list its address as a synchronized mailbox. Connecting it on another
device still requires choosing its provider and reviewing its endpoint as well as
entering its password; the synchronized address alone grants no server access.

After a successful password repair, a retained Inbox that reported authentication
failure reloads immediately on both hosts. Only the repaired connection retries;
Private Sync checks, Profile changes and failed repairs do not retry other refused
IMAP Inboxes.

## Failures and recovery

Setup failures keep the Product Account. A first mailbox that fails records why, so the
reason survives relaunch:

| Reason          | Shown when                                               |
| --------------- | -------------------------------------------------------- |
| `imap-refused`  | The server refused the user name and password            |
| `imap-insecure` | TLS could not be established with a verified certificate |
| `smtp-refused`  | The SMTP server refused the user name and password       |
| `smtp-insecure` | SMTP offered no verified TLS, implicit or by STARTTLS    |
| `imap-offline`  | A server could not be reached, or any other failure      |

Adding another IMAP mailbox beside existing ones reports the failure in the form and
changes nothing. Every launch logs in to each IMAP connection again. A refused password
marks it **The mail server needs your password again**. **Enter password again**
opens Settings on **Email Accounts**, where the connection can be repaired
immediately without relaunching, including when **Open Inbox** has deferred
Recovery Key setup. Password entry is also available for an IMAP connection awaiting a
password on this device. Other failures keep its saved Inbox open from this device;
Email Accounts labels it as saved mail awaiting another server check.

## Synchronization

Synchronization policy and the encrypted cache belong to the shared client; native
code owns authenticated transport. Reading is read-only and never sets `\Seen`.

- A message is identified by its folder, UIDVALIDITY and UID together. A new
  UIDVALIDITY lists the folder again; nothing read under the earlier one is reused.
  A server that omits UIDVALIDITY or reports zero is refused before message reads;
  the encrypted cache also refuses that unestablished identity.
  An unreadable cache document stays intact and shows an unavailable Inbox;
  synchronization does not replace it with an empty listing.
- The first synchronization lists the newest 200 messages of the folder. Later ones
  send the committed checkpoint (UIDVALIDITY, UIDNEXT and the cached UIDs), read only
  the flags of those UIDs and the messages that arrived since UIDNEXT, and drop cached
  messages the server no longer reports. When more than 200 arrived, only the newest
  200 are read.
- Each folder's messages and checkpoint are committed together to the connection's
  encrypted cache, so an interrupted synchronization repeats only the step that did
  not commit. The Inbox and up to eight other opened folders stay cached.
- After a successful folder synchronization, a saved body is removed when its
  message appears in neither a cached folder's list nor a still-shown view of an
  evicted folder. This includes messages expunged from a folder or replaced by a new
  UIDVALIDITY.
  Bodies for rows still shown from an evicted folder remain eligible for retention.
  Those rows survive an Inbox reload while the folder remains selectable, including
  password repair for the same connection. Closing access or replacing the
  connection owner clears them.
  Open readers keep their in-memory body, and their still-retained saved bodies
  are protected against budget eviction as far as they fit. Cleanup skipped for
  temporary unavailability or a competing cache update retries on a later
  successful synchronization.
- The folder list is read on each synchronization, with the special-use roles the
  server declares. After the refreshed list is saved successfully, a folder it no
  longer offers as selectable leaves the cache, with its views and, at the next
  cleanup, its saved bodies; the Inbox always stays. A failed listing, including
  unavailable namespace discovery or more than 1,000 folders, preserves the prior
  list and cached mail for a later retry. Case variants of the reserved `INBOX` name share that spelling;
  other folder names stay as listed, including folders with an inbox role.

Freshness follows the hosts' application lifecycles. Every Inbox load, including
foreground catch-up, the five-minute poll and each background opportunity iOS grants,
reads the folder list and the Inbox from their checkpoints. When the server advertises
IDLE, one connection per mailbox waits on its Inbox, for at most five minutes at a time,
and reads it again as soon as the server reports a change. The Mac waits for the life of
the application, including after its last window closes; iPhone and iPad wait only while
the app is active. An interrupted wait tries again after a pause that grows to five
minutes, so a refused password or a repaired connection resumes waiting; a server
without IDLE leaves the mailbox to polling. Waiting for IDLE does not block reading
or organizing mail.

The unified Inbox lists each IMAP connection's Inbox folder. The Mailboxes sidebar
lists the connection's selectable folders under it; choosing one shows that folder, and
each Mac window chooses its folder independently. A folder
that cannot be read shows **Folders could not be listed**; its cached messages stay.
The failed read also marks that folder's sidebar row, including after another mailbox
is selected and when the folder has no cached messages.
A chosen folder removed from the refreshed selectable listing falls back to Inbox.
It stays there if that folder name reappears, until the person chooses it again.
Local search marks a body as available on this device only when the body cache
confirms it is saved; listing a message alone does not make its body available offline.

## Reading

Opening a message downloads its source (up to 40 MB), subject to bounded MIME parsing,
and retains the parsed readable body and admitted inline images in the Bounded
Encrypted Body Cache for later opens without the server.
The reader shows sanitized HTML or plain text and inline `cid:` images within the
per-message and shared display budgets, including repeated images and multiple windows.

The current reader supports:

- Remote Message Content is never loaded for IMAP mail; the reader says so, and the
  per-mailbox remote content setting is not offered for IMAP connections.
- Received attachments are counted, not listed or downloadable.
- There is no recent-body prefetch, Reply, Reply All or Forward for IMAP mail; a new
  message can be sent from an IMAP connection, as [Sending](#sending) describes.

A message whose UID no longer exists under the folder's UIDVALIDITY reads as **This
message is no longer in this folder on the mail server**.

## Organizing

IMAP mail offers, in the reader and as Inbox row actions, **Mark as read** or **Mark as
unread**, **Archive**, **Move to Trash**, **Report spam**, and under **Folders**, **Move
to** any other selectable folder, including the Inbox. IMAP has no labels or star.
Archive, Trash and Spam move the message to the folder the server declares with the
`\Archive`, `\Trash` or `\Junk` special-use role; without exactly one selectable folder declaring a role, its action is
not offered, and no folder is guessed by name.

Moves need a server that moves one message without expunging others: MOVE, or else
COPY with UIDPLUS's `UID EXPUNGE` of that message alone. A server with neither offers
only read state; a plain `EXPUNGE`, which would also remove messages other clients marked
deleted, is never sent. A folder opened read-only refuses changes.

Each change shows at once, is saved in the connection's encrypted cache and is sent to
the server in order:

- A change waits while the server cannot be reached, including across relaunch, and the
  Inbox says how many changes wait.
- A change names its folder, UIDVALIDITY and UID. A folder recreated with a new
  UIDVALIDITY, a message another client moved or expunged first, a removed destination
  folder, a changed or ambiguous role mapping and a server refusal each refuse the change, and the Inbox shows the message as
  the server has it. A change never reaches another generation of the folder.
- COPY fallback must save the server's destination identity before deleting its source.
  A later attempt finishes that recorded copy without copying again. A destination whose
  UIDVALIDITY changed, or whose copied message disappeared, refuses source deletion.
- When a move's result is uncertain and no destination identity was saved, it is never
  sent again automatically, even if the source disappeared. The Inbox asks the person to
  check the folders and **Discard change** to let later changes continue. This state
  survives relaunch; discarding makes no additional move.
- **Undo** withdraws a move the server has not received, or moves the message back from
  the UID the server reported for it (COPYUID). A move whose new UID is unknown offers no
  Undo after it is applied.

Read state is kept in the cache once applied; a moved message leaves its folder's cache,
and a cached destination folder is read again so a message moved back shows there.

## Online search

When asked, below the results saved on this device, the server searches the text of the
Inbox and the connection's other selectable folders: folders with a declared role first,
then the rest in listing order, leaving out Trash and Spam as Gmail's search does. One
search covers up to 50 folders and the newest 50 matches of each, and says when folders
or older matches were left out; a folder the server no longer selects is skipped. IMAP
results join Gmail's and Microsoft's in the unified Inbox, newest first, and open in the
reader without being saved.

## Sending

A connection with verified SMTP is offered in **From** like a Gmail mailbox, and its
messages use the [Outbox](outbox.md): the Undo Send Window, the Convex claim, and
durable handoff before submission. Sending also needs exactly one selectable folder
the server declares with the `\Sent` role; without one, Send refuses with **This
mailbox's mail server has no Sent folder to keep a copy, so it cannot send.** A message
waits to send until the connection's folder list has been read.

- Native code inserts the verified file bytes, logs in to SMTP with the connection's
  SMTP password (or its IMAP one), and submits from the connection's address to the To,
  Cc and Bcc recipients. The submitted copy leaves out the Bcc field; the message names
  its own Message-ID.
- A refusal before the server could accept the message keeps it apart from an uncertain
  one. A refused password says **Not sent. The mail server did not accept this
  mailbox's password.**, a server's permanent refusal (including a refused recipient)
  says **Not sent. The mail server refused this message.**, a message over the server's
  advertised size limit is too large, and a temporary refusal, an unreachable server
  or a failed TLS setup waits to send and tries again.
- Once the message's end may have reached the server without a final answer, its
  outcome is **Delivery unknown** and it is never submitted again automatically.
  **Check Again** looks for exactly one copy with its MIME boundary in the Sent folder,
  which confirms it; otherwise it stays unknown until the person chooses **Edit Anyway**.
- A message SMTP accepted is recorded as sent before its copy is filed, and the row says
  **Sent. Saving a copy to Sent…**. Filing appends the message, with its Bcc field,
  read, to the Sent folder unless a copy with its MIME boundary is already there, so a
  lost answer or a relaunch files it again without a second copy and never submits the
  message again. While filing waits, the row says why: the server cannot be reached,
  storage is locked, the password was refused, or the Sent folder is gone. Edit is not
  offered for an accepted message. Removing the connection drops a copy still waiting.

## Engine and dependencies

The engine is [SwiftMail](https://github.com/Cocoanetics/SwiftMail) 1.16.0. Its exact
revisions and linked products are owned by
[`native/private-inbox/Package.swift`](../native/private-inbox/Package.swift), with the
resolved dependency graph in [`Package.resolved`](../native/private-inbox/Package.resolved).
Both hosts must build that graph and pass their `verify:bundle` gate. Incremental
Expo generation must update the pin and restore missing product links.

To update the engine, change the revision in `Package.swift`, run `swift package
resolve` in `native/private-inbox`, commit both files, and update the reviewed list in
both hosts' `scripts/verify-native.ts`. The synthetic metadata check compiles the
sources without Swift packages and gets an engine stub instead.

## Validate

From the workspace root:

```sh
mise exec -- pnpm --filter @private-email/mail-core exec vitest run test/imap.test.ts test/imap-organize.test.ts test/imap-send.test.ts test/imap-registration.test.ts
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer mise exec -- zsh native/private-inbox/integration/test.zsh ios
```

From `native/private-inbox`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter swiftMailRefusesAPlaintextServer
```

The shared organizing tests (`test/imap-organize.test.ts`) cover role mapping and
capability limits, read state, archive with Undo, an outage across relaunch, unknown
move outcomes, durable COPY continuation, concurrent removals, a new UIDVALIDITY,
changed roles, a removed destination, settled folder views, search scope and limits,
and IDLE interruption and recovery. The shared tests use a controlled provider fixture
([`testing/imap-mailbox.ts`](../packages/mail-core/src/testing/imap-mailbox.ts)), rather
than a wire server, through the real Inbox store and encrypted-cache contract. They
also cover registration through the synthetic vault and MIME parsing against
`postal-mime`. The sending journeys (`test/imap-send.test.ts`) run the real Draft store,
Outbox and IMAP Inbox against controlled native bridge fixtures for IMAP and SMTP: one submission from
the sending connection only, a delivered copy without Bcc and a Sent copy with it and
the same Message-ID, a lost filing answer and a relaunch while filing without a second
copy or submission, each refusal before acceptance, an ambiguous acceptance confirmed
only by one Sent copy, a stop after acceptance read as unknown, and refusal without a
Sent folder or verified SMTP. `test/imap-registration.test.ts` checks that SMTP is
verified on its own with its own password and that each form builds its reviewed SMTP
endpoint. The native suite checks password custody, Gmail isolation and stale
operations, SMTP verification before a connection is added, the SMTP password, the
envelope and Bcc removal, refused envelopes, and filing a Sent copy that keeps Bcc. The plaintext-server test exercises the real SwiftMail transport refusing
a connection before credentials are sent.

The hosted iOS runner owns a TLS IMAP protocol fixture, its synthetic certificate,
port and disposable simulator. It installs trust only on that simulator and checks
real engine authentication, folders, incremental UID reads, raw body reads,
UIDVALIDITY refusal, oversized-literal refusal and closed sessions. It also checks
`\Seen` changes, MOVE with COPYUID, COPY with `UID EXPUNGE` on a server without MOVE,
refusal without MOVE or UIDPLUS, a refused destination, a connection dropped after MOVE,
a removed folder, cross-folder search, and IDLE waking on a change and timing out. A
TLS SMTP fixture beside it, with the same certificate, checks real SwiftMail submission
over implicit TLS and STARTTLS, leaving a server without STARTTLS before any password,
a refused password, a temporary refusal, a refused recipient without partial delivery,
a permanent refusal after the message, and interruptions at MAIL FROM, RCPT TO, DATA,
during content, and after the message's end. Content-phase interruptions remain unknown;
earlier interruptions remain safe to retry. The IMAP fixture checks
the Sent copy's header search and a single APPEND that filing again finds. Its certificate
never changes production validation or trust on the host Mac.

Real iCloud Mail and Fastmail read, organizing, search, IDLE, SMTP submission and Sent
filing qualification remains required before release
([#632](https://github.com/unwired-dev/product/issues/632)), as do native Mac
controlled-TLS reads and complete native IMAP setup/open/relaunch journeys on both
hosts. Native Mock Mail Sessions currently refuse IMAP connection attempts; the shared
controlled-provider fixture is not native mock or provider qualification.
