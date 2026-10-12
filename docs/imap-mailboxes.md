# IMAP mailboxes

Setup, coding rules, validation and observable requirements remain in this file.

[#629](https://github.com/unwired-dev/product/issues/629) connects a
**Standards-Based Mailbox Connection** over IMAP and reads its folders and messages on
iPhone, iPad and Mac. Sending through SMTP is [#631](https://github.com/unwired-dev/product/issues/631),
so every IMAP connection is **receive only** until then. Organizing and server search
are [#630](https://github.com/unwired-dev/product/issues/630); certification against
real iCloud Mail and Fastmail mailboxes is [#632](https://github.com/unwired-dev/product/issues/632).

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
any mailbox is connected, the account page's **Mailboxes** section also offers **Add an
IMAP mailbox**.

## Endpoints and passwords

| Provider            | IMAP server           | Port    | User name                          |
| ------------------- | --------------------- | ------- | ---------------------------------- |
| iCloud Mail         | `imap.mail.me.com`    | 993     | The name part of the address       |
| Fastmail            | `imap.fastmail.com`   | 993     | The full address                   |
| Another IMAP server | Entered by the person | Entered | Entered, or the address when blank |

iCloud Mail retries once with the full address when the server refuses the name
part, following [Apple's mail settings](https://support.apple.com/en-us/102525).
A successful retry saves that user name for later password repair. A refused full
address, an unreachable server or a TLS failure is not retried this way.

The form shows the endpoint it will contact before **Connect**. iCloud Mail and
Fastmail require an app-specific password; the form says so. Every connection uses
**Secure Mail Transport**: TLS from the first byte (implicit TLS), TLS 1.2 or newer, and
certificate verification against the system's trusted roots with no override. A server
that offers no verified TLS is refused before any credential is sent. STARTTLS and
plaintext ports are not offered in this slice.

Native code owns IMAP password custody. The password is supplied only when connecting
or repairing a connection; it is never returned to JavaScript or sent to Convex,
Product Sync or Google. Hosts may receive the address and reviewed endpoint, without
its password.

The connection is identified by its endpoint and user name, so connecting the same
account again repairs it with the new password instead of adding a second one. Its
synchronized Product Sync descriptor names provider `imap` and the address; other
Trusted Devices list its address as a synchronized mailbox. Connecting it on another
device still requires choosing its provider and reviewing its endpoint as well as
entering its password; the synchronized address alone grants no server access.

After a successful password repair, a retained Inbox that reported authentication
failure reloads immediately on both hosts. Only the repaired connection retries;
Product Sync checks, Profile changes and failed repairs do not retry other refused
IMAP Inboxes.

## Failures and recovery

Setup failures keep the Product Account. A first mailbox that fails records why, so the
reason survives relaunch:

| Reason          | Shown when                                               |
| --------------- | -------------------------------------------------------- |
| `imap-refused`  | The server refused the user name and password            |
| `imap-insecure` | TLS could not be established with a verified certificate |
| `imap-offline`  | The server could not be reached, or any other failure    |

Adding another IMAP mailbox beside existing ones reports the failure in the form and
changes nothing. Every launch logs in to each IMAP connection again. A refused password
marks it **The mail server needs your password again**. **Enter password again**
opens the account page, where the connection can be repaired immediately without
relaunching. Password entry is also available for an IMAP connection awaiting a
password on this device. Other failures keep its saved Inbox open from this device;
the account page labels it as saved mail awaiting another server check.

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
- After a successful folder synchronization, saved bodies no cached folder lists
  and no evicted folder view still shows are removed, including messages expunged
  or replaced by a new UIDVALIDITY.
  Bodies for rows still shown from an evicted folder remain eligible for retention.
  Those rows survive an Inbox reload, including password repair for the same
  connection. Closing access or replacing the connection owner clears them.
  Open readers keep their in-memory body, and their still-retained saved bodies
  are protected against budget eviction as far as they fit. Cleanup skipped for
  temporary unavailability or a competing cache update retries on a later
  successful synchronization.
- The folder list is read on each synchronization, with the special-use roles the
  server declares. Case variants of the reserved `INBOX` name share that spelling;
  other folder names stay as listed, including folders with an inbox role.

The unified Inbox lists each IMAP connection's Inbox folder. Choosing the connection on
its own shows its folders; each Mac window chooses its folder independently. A folder
that cannot be read shows **Folders could not be listed**; its cached messages stay.
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
- There is no recent-body prefetch, Reply, Reply All, Forward, organizing or online
  search for IMAP mail.

A message whose UID no longer exists under the folder's UIDVALIDITY reads as **This
message is no longer in this folder on the mail server**.

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
mise exec -- pnpm --filter @private-email/mail-core exec vitest run test/imap.test.ts
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer mise exec -- zsh native/private-inbox/integration/test.zsh ios
```

From `native/private-inbox`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter swiftMailRefusesAPlaintextServer
```

The shared tests use a controlled provider fixture
([`testing/imap-mailbox.ts`](../packages/mail-core/src/testing/imap-mailbox.ts)), rather
than a wire server, through the real Inbox store and encrypted-cache contract. They
also cover registration through the synthetic vault and MIME parsing against
`postal-mime`. The native suite checks password custody, Gmail isolation and stale
operations. The plaintext-server test exercises the real SwiftMail transport refusing
a connection before credentials are sent.

The hosted iOS runner owns a TLS IMAP protocol fixture, its synthetic certificate,
port and disposable simulator. It installs trust only on that simulator and checks
real engine authentication, folders, incremental UID reads, raw body reads,
UIDVALIDITY refusal, oversized-literal refusal and closed sessions. Its certificate
never changes production validation or trust on the host Mac.

Real iCloud Mail and Fastmail read qualification remains required before release
([#632](https://github.com/unwired-dev/product/issues/632)), as do native Mac
controlled-TLS reads and complete native IMAP setup/open/relaunch journeys on both
hosts. Native Mock Mail Sessions currently refuse IMAP connection attempts; the shared
controlled-provider fixture is not native mock or provider qualification.
