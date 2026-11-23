# IMAP mailboxes

Setup, coding rules, validation and observable requirements remain in this file.

[#629](https://github.com/unwired-dev/product/issues/629) connects a
**Standards-Based Mailbox Connection** over IMAP and reads its folders and messages on
iPhone, iPad and Mac. [#631](https://github.com/unwired-dev/product/issues/631) sends
through its SMTP server and files a copy in its Sent folder; a connection is complete
only once both its IMAP and SMTP logins verified. [#630](https://github.com/unwired-dev/product/issues/630)
organizes and searches IMAP mail at the server and keeps it fresh with IDLE where the
server offers it; certification against real iCloud Mail and Seznam Email mailboxes is
[#632](https://github.com/unwired-dev/product/issues/632).

## First mailbox and provider choice

After Google or Apple Product Sign-In and device admission, the account page starts
no mailbox authorization on its own. **Connect your mail** lists the providers as rows,
each opening its own setup:

- **Gmail**, which suggests the Google sign-in account, and below the list **Choose
  Another Google Mailbox**;
- **iCloud Mail**, **Fastmail** and **Other IMAP Account**, whose IMAP form opens in
  place, with **Cancel** returning to the list;
- **Microsoft 365 and Outlook** when this build is configured for
  [Microsoft mail](microsoft-mail.md).

Choosing an IMAP provider asks for no Google or Microsoft grant. Saved Gmail and
Microsoft mailboxes that all need authorization again are still authorized again right
after sign-in; an IMAP password is only ever entered again in Settings' **Email Accounts**. Once
any mailbox is connected, Settings' **Email Accounts** also offers **Add an
IMAP Mailbox**.

## Endpoints and passwords

| Provider           | IMAP server           | Port    | User name                          |
| ------------------ | --------------------- | ------- | ---------------------------------- |
| iCloud Mail        | `imap.mail.me.com`    | 993     | The name part of the address       |
| Fastmail           | `imap.fastmail.com`   | 993     | The full address                   |
| Other IMAP Account | Entered by the person | Entered | Entered, or the address when blank |

| Provider           | SMTP server           | Port and security                        | User name                               |
| ------------------ | --------------------- | ---------------------------------------- | --------------------------------------- |
| iCloud Mail        | `smtp.mail.me.com`    | 587, STARTTLS                            | The full address                        |
| Fastmail           | `smtp.fastmail.com`   | 465, SSL/TLS                             | The full address                        |
| Other IMAP Account | Entered by the person | Entered; SSL/TLS on 465, else STARTTLS\* | Entered, or the IMAP user name if blank |

\* The form's **SSL/TLS** or **STARTTLS** choice follows the port until the person
chooses one.

iCloud Mail retries once with the full address when the server refuses the name
part, following [Apple's mail settings](https://support.apple.com/en-us/102525).
A successful retry saves that user name for later password repair. A refused full
address, an unreachable server or a TLS failure is not retried this way.

The form shows both endpoints it will contact before **Connect**. iCloud Mail and
Fastmail require an app-specific password, which signs in to both IMAP and SMTP; the
form says so. The Other IMAP Account form adds an **Incoming (IMAP)** group for the
user name, server and port, and an **Outgoing (SMTP)** group: server,
port, **SSL/TLS** or **STARTTLS**, and optionally an SMTP user name and password when
they differ from the incoming ones. Wrapping guidance beside each SMTP credential
field explains the incoming default even after a value is entered. Every connection uses **Secure Mail Transport**:
TLS 1.2 or newer and certificate verification against the system's trusted roots with
no override. IMAP uses TLS from the first byte (implicit TLS); STARTTLS and plaintext
IMAP ports are not offered. SMTP uses implicit TLS, or STARTTLS that the server must
offer before any authentication; a server that offers neither is left before any
credential is sent.

### Catalogued providers

[#2176](https://github.com/unwired-dev/product/issues/2176) on the Mac and
[#2189](https://github.com/unwired-dev/product/issues/2189) on iPhone and iPad fill in the
Other IMAP Account form from a bundled reviewed catalog, matched by the address's domain. Until
the person changes a server setting, the servers, ports, security and user name follow
the address: a catalogued domain fills them in and shows **Found server settings for
_domain_. Port and security are filled in for you.**, and any other domain leaves them
empty for manual entry. Once the person changes one, the address no longer changes
them. The person still reviews both endpoints before **Connect**, and the lookup
happens on the device.

For a domain the catalog does not list, [#2200](https://github.com/unwired-dev/product/issues/2200)
looks up the domain's [RFC 6186](https://www.rfc-editor.org/rfc/rfc6186.html) SRV records
through the system resolver once the address has stopped changing for half a second:
`_imaps._tcp` for IMAP, and `_submissions._tcp` ([RFC 8314](https://www.rfc-editor.org/rfc/rfc8314.html))
or else `_submission._tcp` for SMTP, each choosing among the records of the lowest priority at
random in proportion to their weights, as [RFC 2782](https://www.rfc-editor.org/rfc/rfc2782.html)
describes. A target of `.` means the service is not offered. When both are found,
the form fills in the servers and ports, signs in with the full address and shows the same
note; otherwise it stays empty for manual entry. SMTP found through `_submissions` uses SSL/TLS
on whatever port it names; SMTP found through `_submission` takes security from its port, since
some domains list implicit TLS on 465 there. A server setting the person changed, or a later address, discards an answer still on its way. Only the
system resolver sees the domain, and Secure Mail Transport checks the discovered host's
certificate as it does any other. On 15 November 2026 the lookup filled in `posteo.de`,
`migadu.com` and `purelymail.com`, and left `mailbox.org` and `example.org`, which publish
no records, to manual entry.

Every entry comes from the provider's own settings page and signs in with the full
address, except iCloud Mail's IMAP user name as in the table above. Where a provider
offers both, SMTP uses implicit TLS on 465.

| Domains                                                                           | IMAP server           | SMTP server, port and security      | Source                                                                                                     |
| --------------------------------------------------------------------------------- | --------------------- | ----------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `icloud.com`, `me.com`, `mac.com`                                                 | `imap.mail.me.com`    | `smtp.mail.me.com`, 587, STARTTLS   | [Apple](https://support.apple.com/en-us/102525)                                                            |
| `fastmail.com`, `fastmail.fm`                                                     | `imap.fastmail.com`   | `smtp.fastmail.com`, 465, SSL/TLS   | [Fastmail](https://www.fastmail.help/hc/en-us/articles/1500000278342)                                      |
| `yahoo.com`, `ymail.com`, `rocketmail.com`, `yahoo.co.uk`, `yahoo.de`, `yahoo.fr` | `imap.mail.yahoo.com` | `smtp.mail.yahoo.com`, 465, SSL/TLS | [Yahoo](https://help.yahoo.com/kb/SLN4075.html)                                                            |
| `aol.com`                                                                         | `imap.aol.com`        | `smtp.aol.com`, 465, SSL/TLS        | [AOL](https://help.aol.com/articles/how-do-i-use-other-email-applications-to-send-and-receive-my-aol-mail) |
| `gmx.com`                                                                         | `imap.gmx.com`        | `mail.gmx.com`, 465, SSL/TLS        | [GMX](https://support.gmx.com/pop-imap/imap/server.html)                                                   |
| `gmx.net`, `gmx.de`, `gmx.at`, `gmx.ch`                                           | `imap.gmx.net`        | `mail.gmx.net`, 465, SSL/TLS        | [GMX](https://hilfe.gmx.net/pop-imap/imap/imap-serverdaten.html)                                           |
| `web.de`                                                                          | `imap.web.de`         | `smtp.web.de`, 465, SSL/TLS         | [WEB.DE](https://hilfe.web.de/pop-imap/imap/imap-serverdaten.html)                                         |
| `mail.com`                                                                        | `imap.mail.com`       | `smtp.mail.com`, 465, SSL/TLS       | [mail.com](https://support.mail.com/pop-imap/imap/server.html)                                             |
| `seznam.cz`, `email.cz`, `post.cz`                                                | `imap.seznam.cz`      | `smtp.seznam.cz`, 465, SSL/TLS      | [Seznam](https://napoveda.seznam.cz/cz/email/imap-pop3-smtp/)                                              |

Every IMAP server uses port 993. On 14 November 2026 each endpoint completed a TLS 1.2
handshake whose certificate verified for its host name.

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
Email Accounts labels it as saved mail awaiting another server check. On iPhone, an IMAP
connection's **Enter the Password…** and **Remove…** are rows of their own below its
address, so the address and summary keep the row's width; iPad keeps them as buttons in
the connection's row.

## Synchronization

Synchronization policy and the encrypted cache belong to the shared client; native
code owns authenticated transport. Reading is read-only and never sets `\Seen`.

- A message is identified by its folder, UIDVALIDITY and UID together. A new
  UIDVALIDITY lists the folder again; nothing read under the earlier one is reused.
  A server that omits UIDVALIDITY or reports zero is refused before message reads;
  the encrypted cache also refuses that unestablished identity.
  An unreadable cache document stays intact and shows an unavailable Inbox;
  synchronization does not replace it with an empty listing.
- On iPhone and iPad, pulling down the list synchronizes the shown folder, or the
  Inbox of each shown connection, as described for the
  [Gmail Inbox](gmail-inbox.md#gmail-inbox-synchronization). With another folder
  shown, pulling down and **Try Again** also synchronize the connection, so a
  recovered connection leaves the Attention state.
- The first synchronization lists the newest 200 messages of the folder. Later ones
  send the committed checkpoint (UIDVALIDITY, UIDNEXT and the cached UIDs), read only
  the flags of those UIDs and the messages that arrived since UIDNEXT, and drop cached
  messages the server no longer reports. When more than 200 arrived, only the newest
  200 are listed, cached and notified. For the Inbox, the older arrivals' envelopes
  are also read in UID pages of up to 200, newest first, down to the checkpoint, so
  mail another client expunges meanwhile shifts nothing, and only screened for
  [Blocked Senders](architecture/product/organization.md#mute-and-blocked-senders)
  ([#2122](https://github.com/unwired-dev/product/issues/2122)).
- Each folder's messages and checkpoint are committed together to the connection's
  encrypted cache, so an interrupted synchronization repeats only the step that did
  not commit. The Inbox and up to eight other opened folders stay cached.
  The Inbox's commit also records when its synchronization started, which the
  list subtitle reports as the connection's
  [last update](gmail-inbox.md#behavior).
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
  server declares. The unified Sent, Archive, Spam and Trash mailboxes under
  Favorites list the one selectable folder declaring `\Sent`, `\Archive`, `\Junk` or
  `\Trash`; without exactly one such folder, or when that folder is also the
  server's `\All` folder, the mailbox shows as not included. All Mail lists every
  selectable folder outside Junk, Trash and a virtual `\Flagged` folder. A server
  with a selectable `\All` folder is not included there, since that folder may hold
  Junk, Trash and mail found nowhere else. A server that doesn't mark exactly one
  selectable `\Junk` and one `\Trash` folder is not included either, with a notice
  that it doesn't say which folders hold Spam and Trash; a folder named like one is
  never taken for it. The connection can instead store chosen Spam and Trash
  folders. Choose Folders… under that All Mail notice opens a sheet (on the Mac, an
  AppKit sheet on that window) listing the connection's folders by name in a system menu for each role the
  server leaves unmarked, with nothing chosen for the person; the Inbox, folders
  holding another role and the other role's choice are dimmed, and a role the server
  marks shows its folder without a menu. Save waits for an existing folder for each
  such role; a failed save keeps the sheet open with the previous choice in use, and a
  saved folder the server no longer lists is marked unavailable so another can be chosen. On the
  Mac, Return saves and Escape cancels. Settings › Email Accounts also lists each such
  connection under Spam and Trash Folders: before a choice its row warns which role is
  not chosen and that the connection is not in All Mail, and after one it names both
  folders; Choose Folders… or Change… (the whole row on iPhone) opens the same sheet
  with the saved folders, on the Mac as a sheet on the Settings window. The choice
  synchronizes through Product Sync for that connection only
  until it is removed; a device that has not yet learned another device removed and
  added the connection again cannot save over the new connection's choice. A chosen folder supplies a role only where the server marks no
  folder with it, and a server marking still wins. A server marking several folders
  with a role offers no choice and stays out of All Mail, since choosing one would
  leave the others' mail in it; Move to Inbox still works from each of those folders.
  Once each role resolves to one folder, the choice serves Spam, Trash
  and All Mail as well as Delete, Move to Spam, moving mail back to the Inbox
  and search, for mail already read as well as later synchronizations, without
  reading the mail again. A chosen folder that the saved listing no longer offers as
  selectable leaves the role unknown, so the connection is not included again until
  it returns or another is chosen; no other folder is substituted. A queued move not yet attempted
  is refused, like other role changes, once the choice points the role elsewhere. A
  choice that cannot be saved, including a folder chosen for both roles, keeps the
  previous one. Sent still needs a folder the server marks `\Sent`. After the refreshed list is saved successfully, a folder it no
  longer offers as selectable leaves the cache, with its views and, at the next
  cleanup, its saved bodies; the Inbox always stays. A failed listing, including
  unavailable namespace discovery or more than 1,000 LIST responses, preserves the
  prior list and cached mail for a later retry. A server may refuse a LIST of another
  user's or a shared namespace, for its root or for the folders under it, and SwiftMail
  then skips it and merges the rest without saying which it skipped. The cached mail and
  views of a folder the listing leaves out that such a LIST would match, in any letter case and reading `*` and
  `%` as wildcards, therefore stay, so folders of other users' and shared namespaces stay
  cached after they are removed ([#2690](https://github.com/unwired-dev/product/issues/2690)).
  A folder whose match would take too long stays as well. Should a new namespace discovery
  change the LIST patterns, in content or order, while the listing runs, the refresh fails and keeps the prior list. Only the listing names folders and their roles, so such a folder leaves the folder list
  and never serves as Sent, Drafts or another role. Listing stops reading at the 1,001st
  LIST response the server sends, across all namespaces and before duplicate names
  merge, and closes that session. Case
  variants of the reserved `INBOX` name share that spelling; other folder names
  stay as listed, including folders with an inbox role.

Freshness follows the hosts' application lifecycles. Every Inbox load, including
foreground catch-up, the five-minute poll and each background opportunity iOS grants,
reads the folder list and the Inbox from their checkpoints. When the server advertises
IDLE, one connection per mailbox waits on its Inbox, for at most five minutes at a time,
and reads it again as soon as the server reports a change. The Mac waits for the life of
the application, including after its last window closes; iPhone and iPad wait only while
the app is active. An interrupted wait tries again after a pause that grows to five
minutes, so a refused password or a repaired connection resumes waiting; a server
without IDLE leaves the mailbox to polling. Waiting for IDLE does not block reading
or organizing mail. New, removed or changed messages read the Inbox again; the
server closing the connection pauses before the next wait; other events, such as an
alert or a changed flag list, keep the wait going until its bound. Stopping a wait
closes its session at once.

The unified Inbox lists each IMAP connection's Inbox folder. The Mailboxes sidebar
lists the connection's selectable folders under it; choosing one shows that folder, and
each Mac window chooses its folder independently. A folder
that cannot be read shows **Folders could not be listed**; its cached messages stay.
The failed read also marks that folder's sidebar row, including after another mailbox
is selected and when the folder has no cached messages. A problem of the whole connection,
such as a password the server no longer accepts, shows as a warning beside the
connection's sidebar header, as in the [Gmail guide](gmail-inbox.md#behavior). On iPhone,
while the connection needs its password again, a banner above its folders also offers
**Enter the Password…**, which opens Settings' Email
Accounts.
A chosen folder removed from the refreshed selectable listing falls back to Inbox.
It stays there if that folder name reappears, until the person chooses it again.
Local search marks a body as available on this device only when the body cache
confirms it is saved; listing a message alone does not make its body available offline.

### Historical Metadata Backfill

Once the Inbox is current, each connection downloads the metadata of every selectable
folder in the background, Inbox first and then the folders in listed order, as the
[Gmail backfill](gmail-inbox.md#historical-metadata-backfill) does for All Mail. It
reads no message bodies and yields to synchronization, message opens and the
changes a person makes.
Recent-body prefetch and history share one speculative lane per connection. A
failure pauses both kinds of work until the next Inbox synchronization.

- Each read examines one folder and searches bounded UID windows below its cursor,
  newest first, keeping at most 500 messages. A window starts at the page size and
  grows to at most 65,536 UIDs over at most eight searches, so sparse folders advance
  without unbounded requests. Reported ranges are clamped to the searched window
  before they are expanded.
- Each read's messages are saved as one encrypted history segment beside the mailbox
  document, committed with the folder's checkpoint: its UIDVALIDITY, the UID cursor,
  the UIDNEXT the pass started from and the server's message count. An interrupted
  read or a relaunch resumes from the last committed cursor. A changed UIDVALIDITY
  discards that folder's history and restarts only that folder.
- When a pass reaches the oldest UID, messages that arrived since the pass started
  are read in a further pass. When the downloaded count then exceeds the server's
  message count, every segment is checked against the server, at most 500 known UIDs
  per read, and messages expunged meanwhile are removed. A completed folder is
  checked once per launch and read again after new arrivals.
- History does not count against the Inbox's 200 recent messages or the eight cached
  folders: evicting an opened folder's cache keeps its history. A folder the refreshed
  list no longer offers leaves the history with its segments.
- The IMAP Inbox state reports downloaded messages, the folders' total once every
  folder has begun, whether the history is complete, and whether it is paused. The
  [sync status](gmail-inbox.md#sync-status-capsule) shows this progress as it does for
  Gmail. A failed read pauses the download until the next Inbox synchronization and
  keeps its checkpoints. A refused password marks the connection as needing its
  password again, as synchronization does. A folder that is gone or refuses its
  UIDVALIDITY is skipped until the next launch.

Downloaded history is not shown in folder lists or searched yet. Scrolling past a
folder's cached messages still shows only those messages.

## Reading

Opening a message downloads its source (up to 40 MB), subject to bounded MIME parsing,
and retains the parsed readable body and admitted inline images in the Bounded
Encrypted Body Cache for later opens without the server.
The reader shows sanitized HTML or plain text and inline `cid:` images within the
per-message and shared display budgets, including repeated images and multiple windows.
A reader held back by the shared budget shows its images once a Gmail or IMAP reader closes
or hides Remote Message Content, or Gmail removes a message from its cached views
or refreshes it to a smaller presentation.

Remote Message Content in IMAP mail follows the device's remote content policy and the
connection's own setting in Settings, with the same **Load Images** consent, Authorized
Remote Content Cache, tracking-pixel blocking and shared display budget as
[Gmail mail](gmail-inbox.md#links-and-blocked-remote-content). Cached images belong to the
connection and the message's UIDVALIDITY and UID, so a folder with a new UIDVALIDITY
restores none of them. Closing a message's last reader, or its Inbox, ends its remote loads.

[#1020](https://github.com/unwired-dev/product/issues/1020) lists the opened message's
received attachments below its body, with the same rows, limits, protected local
storage and **Download**, **Cancel**, **Open**, **Share** and **Attach to New Message**
actions as [Gmail's received attachments](gmail-inbox.md#received-attachments):

- **Listing.** The list comes from the message source read to open the body, is kept
  with the saved body and makes no further server request.
- **Download.** **Download** reads the message's source again at its folder's
  UIDVALIDITY and saves the attachment only if its position, name, type and size are
  unchanged and its bytes decode to that size. Attachments over 25 MiB are listed as
  **Too large to download on this device.**
- **Cancel.** **Cancel** returns the attachment row to **Download** at once and
  discards the cancelled result. It also cancels the native read of the source, which
  closes that read's IMAP session and so ends the transfer on the wire. The read
  counts against the connection's and device's concurrent reads until native code
  reports that it ended. Closing the last reader ends a body read the same way.
- **Failure.** The row says why and offers **Try Again**: **The mail server could not
  be reached to download this attachment.**, **The mail server needs your password
  again to download this attachment.** (the Inbox also asks for the password),
  **This attachment didn’t download. Choose Try Again to download it.** or the locked-storage
  message. **This attachment is no longer in this folder on the mail server.** has no
  **Try Again**.
- **Removal.** A saved file is deleted when the message's last reader closes, the
  Inbox closes, and with the connection, sign-out, account deletion, device removal
  and relaunch. Like saved bodies, attachments follow the folder identity the
  connection's encrypted cache commits: once a successful folder synchronization
  records a new UIDVALIDITY, the saved files of the folder's earlier messages are
  deleted and their downloads in flight are dropped, even while a reader still
  shows one or the folder had left the cache. Their rows then say the attachment
  is no longer in the folder. A search result or a refused read changes no other
  attachment until that synchronization.

[#1023](https://github.com/unwired-dev/product/issues/1023) offers **Reply**,
**Reply All** and **Forward** for IMAP mail as for Gmail's
[replies and forwards](drafts.md#replies-and-forwards), once the opened message's body
and headers are read and only while the receiving connection can [send](#sending). A
receive-only connection offers none. The Draft sends from the connection that received
the message, with its In-Reply-To and References headers but no thread, because IMAP
has no conversation identifier. Forward copies the received attachments through the
attachment downloads above. Saved bodies keep the headers a response needs; a body
saved before they were kept is read from the server again when opened, and while the
server cannot be reached it opens as saved without the response actions. Responses
follow the folder identity like attachments: once a new UIDVALIDITY supersedes the
opened message, it offers none. Real-provider qualification remains under
[#632](https://github.com/unwired-dev/product/issues/632).

[#1021](https://github.com/unwired-dev/product/issues/1021) saves recent Inbox bodies
before they are opened, under Gmail's
[recent-body prefetch](gmail-inbox.md#recent-body-prefetch) and
[cache admission](gmail-inbox.md#cache-admission-and-eviction) rules:

- **Selection.** After each successful Inbox synchronization, the cached newest 200
  Inbox messages received in the 30 days up to that synchronization are read newest
  first. Other folders and messages already saved or marked are not read.
- **Preflight.** Reads of the selected messages' Content-Type and Content-Disposition
  fields, 20 messages at a time and without any body, decide which sources to read.
  Each header literal is bounded to 256 KiB, the MIME header budget; refusal of a
  larger literal keeps the read's messages on demand with exclusion markers. Only a
  message that is a single plain-text or HTML part, with well-formed MIME fields within
  their budgets, is read and saved; the source is checked again before saving. Any
  other message, one over 40 MB or one that cannot be read, gets an encrypted
  exclusion marker and stays on demand, so prefetch never downloads an attachment.
- **Loads and pauses.** Prefetch is one lane per connection. It holds at most one of
  the connection's two body loads and yields the device's four to every explicit
  read; an open of a message being prefetched waits for that read. An unreachable
  server stops it until the next synchronization; a refused password stops it and
  asks for the password again. Cache-only registration and a closed Inbox start none.
- **Identity.** A prefetched body follows the folder's committed UIDVALIDITY like an
  opened one: a read still in flight when a synchronization records a new UIDVALIDITY
  or drops the message saves nothing, including when another store commits that change,
  and pruning removes earlier bodies.
- **Protection.** Open readers' and then the selected messages' saved bodies are
  protected from budget eviction as far as they fit. Prefetched bodies use the
  prefetched eviction tier, and opening one keeps that tier.

Local search reports a prefetched body as saved on this device.

The 20-UID request limit and 256 KiB per-literal limit do not bound aggregate
memory when a server sends extra or repeated replies, or several individually
legal literals per message. The owner accepted this residual SwiftMail risk
for [PR #1185](https://github.com/unwired-dev/product/pull/1185), with receive-time
aggregate refusal tracked in [#1187](https://github.com/unwired-dev/product/issues/1187).
Prefetch is not qualified against that server behavior.

A message whose UID no longer exists under the folder's UIDVALIDITY reads as **This
message is no longer in this folder on the mail server**.

## Organizing

IMAP mail offers, in the reader and as Inbox row actions, **Mark as Read** or **Mark as
unread**, **Archive**, **Delete**, **Move to Spam**, and
under **Folders**, **Move to** any other selectable folder, including the Inbox. In the
folders the server declares as Trash or Spam (`\Trash`, `\Junk`), or chosen for them as
[Synchronization](#synchronization) describes, **Move to Inbox** takes
the place of Archive, Delete and Move to Spam, as in Gmail's Trash and Spam (the
iPhone and iPad reader names it **Not Spam** in Spam); it offers no Undo. IMAP has no labels. Opening an unread message sets its `\Seen` flag, as
[Organizing mail](gmail-inbox.md#organizing-mail) describes for every provider.
The star is the server's `\Flagged` flag, which other mail apps show as a flag. Only
the [Command Palette](command-palette.md) offers **Star** and **Remove Star**: no
toolbar, menu, row action or row marker shows it, and the folder chooser names a
virtual `\Flagged` folder's role Starred. A flag set or cleared elsewhere arrives with
the next synchronization. Starring keeps the reader open and offers no Undo, like a
read-state change. **Pin** is the product's own marker, never `\Flagged`: an
IMAP message is pinned as its own Thread ([Pins](gmail-inbox.md#pins)) by its folder and
UID. Once the server applies a move, Undo's included, the Pin follows the message to the
UID MOVE or COPYUID reported and keeps its date. A server that reports none leaves the
message without an identity to follow, so its Pin is removed rather than left under the
old UID ([#2283](https://github.com/unwired-dev/product/issues/2283)). When Pin storage
refuses the change, as while the device is locked, the Inbox keeps the move and saves it
with the connection's encrypted cache at its next write. A move answered while the cache
itself was locked is held in memory and saved when the cache reopens, so quitting before
then loses it. Each later opening of the Inbox repeats those moves in order until Pin
storage keeps them, also after relaunch; until then the Pin stays under the old UID and
the moved message shows unpinned, and once storage keeps the move no Pin stays under the
old UID ([#2340](https://github.com/unwired-dev/product/issues/2340)).
The folder listing keeps the server's hierarchy delimiter, so the Move picker nests
`Parent/Child` folders and shows a container that holds only folders (`\Noselect`) as
unavailable.
Archive, Trash and Spam move the message to the folder the server declares with the
`\Archive`, `\Trash` or `\Junk` special-use role, or to a selectable Spam or Trash folder
chosen where the server declares none; without one, its action is
not offered, and no folder is guessed by name. The row and reader
[context menus](gmail-inbox.md#organizing-mail) offer their supported actions in the documented order; Archive is row-only and Move to Spam remains outside those menus.

Moves need a server that moves one message without expunging others: MOVE, or else
COPY with UIDPLUS's `UID EXPUNGE` of that message alone. A server with neither offers
only read state and the star among the server's actions (Pin never asks the server); a plain `EXPUNGE`, which would also remove messages other clients marked
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
  check the folders and **Discard Change** to let later changes continue. This state
  survives relaunch; discarding makes no additional move.
- **Undo** withdraws a move the server has not received, or moves the message back from
  the UID the server reported for it (COPYUID). A move whose new UID is unknown offers no
  Undo after it is applied.

Read state and the star are kept in the cache once applied; a moved message leaves its
folder's cache, and a cached destination folder is read again so a message moved back shows
there. A cache saved before the star was kept shows no star until the next synchronization
reads the message's flags.

### Reader actions compared with Gmail

[#1022](https://github.com/unwired-dev/product/issues/1022) audited the
[Gmail reader's](gmail-inbox.md#organizing-mail) actions that need no sending. The IMAP
reader offers each one that applies:

- **Offered as for Gmail:** read state, the star, Archive, Delete, Move to Spam,
  Move to (Folders), Move to Inbox in Trash and Spam, Undo of a move, the row and
  reader context menus and Command Palette commands, VoiceOver row actions, Copy
  Address, Open Link and Copy Link, the received-attachment actions, Remote Message
  Content, on-device summaries and translation.
- **Not offered, deliberately:** **Labels** and label checkboxes, because IMAP organizes
  mail in folders, which Move to covers; the **Thread** view, because IMAP gives the
  app no conversation identifier like Gmail's thread ID; and Gmail's view-based Move to,
  which removes only the shown label, because an IMAP message is in exactly one folder.
- **Offered with sending:** Reply, Reply All and Forward, from a connection with
  verified SMTP, as [Reading](#reading) describes.

## Online search

When asked, below the results saved on this device, the server searches the text of the
Inbox and the connection's other selectable folders: folders with a declared role first,
then the rest in listing order, leaving out Trash and Spam, including chosen ones, as Gmail's search does. One
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

- The shared Inbox leaves the Bcc field, with its folded lines, out of the copy it
  submits; the message names its own Message-ID. Native code inserts the verified file
  bytes, logs in to SMTP with the connection's SMTP password (or its IMAP one), and
  submits from the connection's address to the To, Cc and Bcc recipients.
- A refusal before the server could accept the message keeps it apart from an uncertain
  one. A refused password says **Not sent. The mail server did not accept this
  mailbox's password.**, a server's permanent refusal (including a refused recipient)
  says **Not sent. The mail server refused this message.**, a message over the server's
  advertised size limit is too large, and a temporary refusal, an unreachable server
  or a failed TLS setup waits to send and tries again.
- Once the message's end may have reached the server without a final answer, its
  outcome is **Delivery unknown** and it is never submitted again automatically.
  **Check Again** looks for exactly one copy with its Message-ID in the Sent folder,
  which confirms it; otherwise it stays unknown until the person chooses **Edit Anyway**.
- A message SMTP accepted is recorded as sent before its copy is filed, and the row says
  **Sent. Saving a copy to Sent…**. Filing appends the message, with its Bcc field,
  read, to the Sent folder unless a copy with its Message-ID is already there, so a
  lost answer or a relaunch files it again without a second copy and never submits the
  message again. While filing waits, the row says why: the server cannot be reached,
  storage is locked, the password was refused, or the Sent folder is gone. Edit is not
  offered for an accepted message. Removing the connection drops a copy still waiting.

## Engine and dependencies

The engine is [SwiftMail](https://github.com/Cocoanetics/SwiftMail) 1.18.0, pinned
by its tag's commit. Its exact revisions and linked products are owned by
[`native/private-inbox/Package.swift`](../native/private-inbox/Package.swift), with the
resolved dependency graph in [`Package.resolved`](../native/private-inbox/Package.resolved).
Both hosts must build that graph and pass their `verify:bundle` gate. Incremental
Expo generation must update the pin and restore missing product links.

To update the engine, change the revision in `Package.swift`, run `swift package
resolve` in `native/private-inbox`, commit both files, and update the reviewed list in
both hosts' `scripts/verify-native.ts`. The synthetic metadata check compiles the
sources without Swift packages and gets an engine stub instead.

SwiftMail parses the IMAP wire protocol inside native sessions; TypeScript decides
what to do with the results. The folder listing, folder synchronization, online
search and Sent filing run in TypeScript over short-lived native sessions: native code logs in for a verified
connection at its current generation and returns an opaque handle. It answers one
command at a time: the capabilities, the folders with their LIST attributes, a
read-only EXAMINE of a folder (its UIDVALIDITY, UIDNEXT and message count, refusing a
folder without UIDVALIDITY), and envelopes or flags of that folder's messages by UID,
from a UID onward or by the newest sequence numbers. A search examines one folder and
returns its newest matching UIDs and how many matched in all, refusing a folder the
server no longer selects, one without UIDVALIDITY and a query in a charset the server
cannot search, and failing when the server completes it without reporting the matches
or an ESEARCH item it was asked for; it matches either text or a Sent copy's Message-ID header. Seznam
Email's server drops the connection on a Content-Type header search in a folder
that holds messages ([#2402](https://github.com/unwired-dev/product/issues/2402)),
so a Sent copy is not looked up by its MIME boundary. An append stores an outgoing message, read, in a folder: native
code reads the message from the Outbox and appends it only for a trusted device. UID-set and newest-message requests name at most 200 messages; a UID-range request reads from its starting UID onward.
TypeScript keeps the checkpoint arithmetic, decides which messages to read, and
closes the session when the work ends, whether it succeeded or failed. IDLE runs the
same way: TypeScript checks the capability, then asks the session to wait on a folder
for a bounded time. Native code sends IDLE, ends it with one DONE after the first
event or the bound, whichever comes first, and reports the kinds of events the server
sent until it answers DONE; TypeScript
decides which of them are a change. Native code also
closes a session after 60 seconds unused or 15 minutes open, and when the
connection's generation changes, as on removal, sign-out or a new password.
Closing a session answers a command still in flight at once, and native code
delivers no later result. A connection may hold four open sessions.

Organizing runs the same way. TypeScript plans each saved change over a session:
it selects the folder, checks the UIDVALIDITY and whether the message is still
there, and then sets or clears `\Seen` or `\Flagged`, moves it, or copies it and
deletes the source with `UID EXPUNGE`. Native code offers only select, flags,
store, move, copy and expunge. Each answers with a fixed failure code and refuses
a folder the server opens read-only. A command that fails after it was sent is
reported as interrupted, so TypeScript never resends an uncertain move.
Filing a Sent copy runs the same way: TypeScript searches the Sent folder for the copy's
Message-ID and appends the message in the same session only when no copy is there.

Closing a session also closes its connection at once: in SwiftMail 1.18,
cancelling an active command closes its transport, and disconnecting no longer
waits for that command. The product's proof that a closed session stops its
command on the wire is [#1184](https://github.com/unwired-dev/product/issues/1184). The hosted
close-answers-at-once cases, including a session closed during IDLE, use a
controlled `ImapSession`.

## Validate

From the workspace root:

```sh
mise exec -- pnpm --filter @private-email/mail-core exec vitest run test/imap.test.ts test/imap-organize.test.ts test/imap-send.test.ts test/imap-registration.test.ts test/imap-remote-content.test.ts test/imap-attachments.test.ts test/imap-prefetch.test.ts test/imap-history.test.ts
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer mise exec -- zsh native/private-inbox/integration/test.zsh ios
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer mise exec -- zsh native/private-inbox/integration/history.zsh
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
endpoint. `test/imap-remote-content.test.ts` checks that remote images load only once a
presentation authorizes them, cache restoration and Never, loads ending with the last
reader and the Inbox, a new UIDVALIDITY restoring nothing, and the display budget shared
with Gmail readers. `test/imap-attachments.test.ts` lists an attachment without a server
read, downloads its exact bytes from the message source, opens and shares it, and covers
an unreachable server, a refused password, locked storage, an expunged message,
cancellation that aborts the source read and frees its load once the read ends, a new
UIDVALIDITY with a download in flight, including for a folder that
had left the cache, a body arriving after that change, isolation between folders
whose names contain delimiters, and deletion with the last reader and the Inbox.
`test/imap-history.test.ts` downloads a 1,100-message Inbox and a 600-message Archive
in bounded reads while the Inbox keeps 200 recent messages, pauses on an outage and
resumes after relaunch from the committed cursor, removes a message expunged during the
download and adds one that arrived, restarts only the folder whose UIDVALIDITY changed,
keeps history for a folder evicted from the cache, and reports a refused password.
`native/private-inbox/integration/history.zsh` runs these journeys and the Gmail
history journeys against the real encrypted store in a signed Mac process.
`test/imap-prefetch.test.ts` saves recent single-part bodies after synchronization
without reading the source of a message with an attachment, opens them offline, reads
nothing again at the next synchronization, pauses while the server cannot be reached or
refuses the password and resumes afterwards, preserves that refusal through an overlapping
synchronization and its metadata-conflict retry, protects recent bodies before prefetch
starts, preserves bodies opened
during the header preflight, shares an in-flight prefetch with an
explicit open, and keeps no body read before a new UIDVALIDITY, including one committed
by another store. The fixture dates mail
older than any recent window unless a test dates it. Both hosts' rendered `attachments.test.tsx` journeys download,
retry, open and share an IMAP attachment and delete it when the reader closes. The native suite checks password custody, Gmail isolation and stale
operations, IMAP sessions (one command at a time, their connection generation, the
per-connection limit, expiry, and closing on a new generation, sign-out and an explicit
close that answers a controlled session's command in flight at once), SMTP verification before a connection is added, the SMTP password, the
envelope and Bcc removal, refused envelopes, and filing a Sent copy that keeps Bcc. The plaintext-server test exercises the real SwiftMail transport refusing
a connection before credentials are sent.

The hosted iOS runner owns a TLS IMAP protocol fixture, its synthetic certificate,
port and disposable simulator. It installs trust only on that simulator and checks
real engine authentication, folders, the session's EXAMINE and its envelope and flag
reads (including `UID n:*` naming the newest message below n), raw body reads, the
prefetch preflight's header-only read of unfolded MIME fields,
UIDVALIDITY refusal, oversized-literal refusal, a stalled source read whose cancellation
closes its session at once, and closed sessions. It also checks
`\Seen` changes, MOVE with COPYUID, COPY with `UID EXPUNGE` on a server without MOVE,
refusal without MOVE or UIDPLUS, a refused destination, a connection dropped after MOVE,
a removed folder, cross-folder search, a history read that clamps an oversized UID range
reply to its bounded window, and IDLE over a session waking on a change, timing out, and ending when its
session closes. A
TLS SMTP fixture beside it, with the same certificate, checks real SwiftMail submission
over implicit TLS and STARTTLS, leaving a server without STARTTLS before any password,
a refused password, a temporary refusal, a refused recipient without partial delivery,
a permanent refusal after the message, and interruptions at MAIL FROM, RCPT TO, DATA,
during content, and after the message's end. Content-phase interruptions remain unknown;
earlier interruptions remain safe to retry. The IMAP fixture checks
a session's Message-ID search of the Sent folder and a single APPEND that the search
then finds. Its certificate
never changes production validation or trust on the host Mac.

### Controlled standards server

`mise exec -- zsh native/private-inbox/integration/standards-server.zsh` runs the iOS
suite above against the controlled standards server of
[#2388](https://github.com/unwired-dev/product/issues/2388): Dovecot 2.3 and Postfix 3.7
in a local Docker container ([`standards-server/`](../native/private-inbox/integration/standards-server/))
with synthetic `example.test` mailboxes only. The script makes a certificate authority
for the run, which only the run's disposable simulator trusts, starts a second
container presenting an untrusted self-signed certificate, and removes the containers
and keys afterwards. It needs a running Docker engine. The unchanged engine exercises:

| Endpoint                                              | Result                                                                    |
| ----------------------------------------------------- | ------------------------------------------------------------------------- |
| IMAP 993, implicit TLS, password                      | Login, SPECIAL-USE roles, delivered mail read, searched, marked and moved |
| SMTP 465, implicit TLS, password                      | Submission delivered                                                      |
| SMTP 587, STARTTLS before AUTH, password              | Submission delivered                                                      |
| IMAP 993, Sent folder                                 | Sent copy appended and found by its Message-ID                            |
| IMAP 143, STARTTLS offered, LOGIN allowed without TLS | Refused as insecure; the engine has no IMAP STARTTLS                      |
| SMTP without STARTTLS, AUTH offered in plaintext      | Refused as insecure                                                       |
| IMAP 993 and SMTP 465, untrusted self-signed cert     | Refused as insecure                                                       |

The run then checks the server logs: IMAP authenticated on 993, SMTP
authenticated on 465 and 587, and no credentials reached 143, the plaintext SMTP listener or the
untrusted server.
On 18 November 2026 the run passed all 105 tests of the suite on an iOS 27.0 iPhone 18 Pro
Simulator, built with Xcode 27.2 (27B52) against Docker Engine 29.9.3, from `main` at
`9f706166f` with this change applied. On 19 November 2026 it passed all 105 tests again
with the Message-ID lookup of [#2402](https://github.com/unwired-dev/product/issues/2402),
from `main` at `eb28e204d` with that change applied.

This is not provider certification and does not run on the Mac host, whose trust the
synthetic certificate authority never changes. Pinned certificates are
[#2005](https://github.com/unwired-dev/product/issues/2005).

### Certification mailboxes

`native/private-inbox/integration/providers.zsh [ios|macos]` runs the iOS suite, the
Mac suite or both against the dedicated iCloud Mail and Seznam Email certification
mailboxes of [#2399](https://github.com/unwired-dev/product/issues/2399). Run it under
`op run --env-file <file outside the repository> -- mise exec -- zsh …`, with that file
naming the password-manager fields for `UNWIRED_ICLOUD_ADDRESS`, `UNWIRED_SEZNAM_ADDRESS`
and their mail-client passwords `UNWIRED_ICLOUD_PASSWORD` and `UNWIRED_SEZNAM_PASSWORD`,
as the [operator setup](https://github.com/unwired-dev/product/issues/632) describes. The
script hands them to `test.zsh`, which passes them only to xcodebuild as `TEST_RUNNER_`
variables, so they reach the test process without being written to the generated scheme.
Each host's run writes to an `artifacts/private-inbox/integration.*` directory the script
creates, and each result bundle is kept only as the test results it records. The runs'
output is shown once a scan finds no address, iCloud Mail user name or password in it or in
those directories, which are then kept, also when a test failed or the certification test
did not pass on a host, either of which fails the script. When the scan finds a credential,
cannot read a file or is interrupted, the script removes this run's evidence and fails. The
Mac run needs `UNWIRED_STORAGE_PROFILE`, like `test.zsh macos`. Each mailbox sends one
message to the other through the unchanged engine; the test then reads, marks, moves and
files it, and afterwards tries to remove this run's messages from every INBOX, Sent and
Trash folder of both mailboxes, also when a step failed. The search for messages the server accepted, or may
have, polls for 70 seconds shared by both deliveries; cleanup polls for one the test did not
find for 16 seconds more, shared by both mailboxes, within the test's 120-second allowance.

| Step               | iCloud Mail                                                                               | Seznam Email                                                                                                                                                          |
| ------------------ | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| IMAP 993 login     | Name part of the address, app-specific password                                           | Full address, mail-client password                                                                                                                                    |
| Wrong password     | Refused as an authentication failure on IMAP and SMTP                                     | Refused as an authentication failure on IMAP and SMTP                                                                                                                 |
| SMTP submission    | 587, STARTTLS; delivered to Seznam Email                                                  | 465, SSL/TLS; delivered to iCloud Mail                                                                                                                                |
| Delivered message  | Found by text search, read, marked and moved to Trash using COPY and targeted UID EXPUNGE | Found by text search; envelope, source, `\Seen` cleared and set and MOVE to Trash                                                                                     |
| Folders and roles  | Sent and Trash roles on LIST                                                              | Sent, Drafts, Archive, Junk and Trash roles on LIST                                                                                                                   |
| Sent filing        | The test finds no provider-filed copy, appends one and verifies it by Message-ID and text | No copy filed by the server. The Message-ID lookup finds none, so the copy is appended, and the lookup that follows and a text search each find exactly that one copy |
| Extensions of note | IDLE, ESEARCH, CONDSTORE, QRESYNC, UIDPLUS; no MOVE or SPECIAL-USE                        | MOVE, UIDPLUS; no IDLE, ESEARCH, CONDSTORE or SPECIAL-USE                                                                                                             |

After the owner opened iCloud Mail for the certification account, IMAP LIST returned
INBOX, Sent Messages, Deleted Messages, Drafts, Junk and Archive. LIST marked Sent
Messages and Deleted Messages with Sent and Trash roles. Drafts, Junk and Archive
had no special-use flags. [#2401](https://github.com/unwired-dev/product/issues/2401)

On 19 November 2026 the certification test passed on an iOS 27.0 iPhone 18 Pro
Simulator and macOS 27.2 (26B123) using Xcode 27.2 (27B52) and this change on top of
`4faf00f00`. The iOS suite passed 105 tests and skipped the controlled standards
server test. The Mac suite reported 60 Keychain `.locked` issues across 57 other
tests, as in the first run. The Mac run skipped the controlled standards server
test and three loopback TLS tests. The credential scan passed.

The first run that day, built with Xcode 27.2 (27B52) from `main` at `eb28e204d`
with the certification test applied, passed the certification test on both hosts
with two known issues. iCloud Mail listed only INBOX, and Seznam Email dropped
the connection on a MIME-boundary Sent lookup (#2402). On `592c536af` with the
Message-ID lookup of [#2431](https://github.com/unwired-dev/product/issues/2431)
applied, the iOS suite passed with only the iCloud Mail exception still active.

### Certification runs through the app

Each record holds only non-secret facts: no addresses, passwords or mail content.

On an iPhone or iPad Simulator the operator never types a credential, because the XCTest
runner that drives the Simulator writes the text it types, also when it is read from
standard input, to its own diagnostic log on the Mac
([#2685](https://github.com/unwired-dev/product/issues/2685)). Each address, password and
Recovery Key goes through the Simulator's pasteboard instead, read at run time from the
password manager by running
`native/private-inbox/integration/simulator-credentials.zsh` under
`op run --env-file <file outside the repository>`:

1. `simulator-credentials.zsh copy <udid> <variable>` puts the value on that Simulator's
   pasteboard. Keep **Automatically Sync Pasteboard** in Simulator's Edit menu off, or
   Simulator closed, so the value does not reach the Mac's pasteboard.
2. Long-press the app's field and press **Paste** in the edit menu.
3. `simulator-credentials.zsh clear <udid>` empties the pasteboard at once.
4. When the field shows its text, as **Recovery Key** does, nothing may read the screen
   while it holds the credential: screenshots, accessibility snapshots and agent-device
   commands that wait, settle or target a ref or selector keep what they read in files on
   the Mac. Take the snapshot before pasting, then press the field's action, such as
   **Unlock with Recovery Key**, at the coordinates that snapshot gave, and wait a few
   seconds. Before the next read, empty the field with `fill <x> <y> ""` at its
   coordinates, unless the operator watching the Simulator saw the field go.
5. After the run, with the Simulator deleted,
   `simulator-credentials.zsh scan <variable>... -- <path>...` lists each file under the
   paths that holds any of the passwords or the Recovery Key, also inside compressed
   result bundles. Scan at least `~/.agent-device`, `~/Library/Logs`, Xcode's DerivedData,
   the shell history, the temporary directory, the repository's `artifacts` and the
   operator's scratch files and session transcripts. A match fails the run's credential
   criterion.

- **2026-11-19, iPhone connect and read
  ([#2444](https://github.com/unwired-dev/product/issues/2444)).** Target: Expo client,
  Release build without a Mock Mail Session, iPhone 18 Pro Simulator on iOS 27.0, with the
  development Convex deployment. Build: the app source of
  `3f2363b2abe4acdd2c48dd12e5b5a9c42d0c48fb`. Toolchain: Xcode 27.2 (27B52). Operator:
  agent, with credentials read at run time from the approved password manager. Result:
  pass. Google Product Sign-In created a new Product Account. **iCloud Mail** connected
  with the app-specific password over `imap.mail.me.com` 993 (TLS) and
  `smtp.mail.me.com` 587 (STARTTLS), then **Add an IMAP Mailbox** › **Other IMAP
  Account** filled in `imap.seznam.cz` 993 (TLS) and `smtp.seznam.cz` 465 (SSL/TLS) from
  the catalog for the Seznam Email address, and connected with its mail-client password.
  Each Inbox listed real messages and one opened in the reader with remote images
  held back. The Mailboxes list showed both accounts' folders, including Seznam Email's
  `drafts`, `archive`, `spam` and `trash`. Limitations: Product Sync logged an
  unavailable failure right after sign-in, the `pullDrafts` pull failed as unavailable
  once the first IMAP mailbox connected, and Account & Devices showed the Gmail
  pending-changes notice on this account without a Gmail mailbox
  ([#2390](https://github.com/unwired-dev/product/issues/2390)). Mac, iPad,
  organizing, search, attachments, sending, IDLE, Sent filing, relaunch and recovery were
  not run and stay on #632.
- **2026-11-19, iPhone send and reply
  ([#2450](https://github.com/unwired-dev/product/issues/2450)).** Target, build,
  toolchain and operator as in the record above, with both certification mailboxes
  connected through the app the same way. Result: pass. A new message from iCloud Mail
  went through the Outbox, SMTP `smtp.mail.me.com` 587 (STARTTLS) accepted it, the row
  left the Outbox and the message appeared in the Seznam Email Inbox in the app. A reply
  from Seznam Email went out over `smtp.seznam.cz` 465 (SSL/TLS) and appeared in the
  iCloud Mail Inbox in the app. Over IMAP, its `In-Reply-To` named the original's
  Message-ID and its `References` included it, and each sending mailbox's Sent folder held
  exactly one copy, with the same Message-ID as the delivered message. In the app,
  Seznam Email's `sent` folder listed exactly one copy of the reply. A later message from
  iCloud Mail showed **Sending soon** with **Undo**, then **Sent. Saving a copy to
  Sent…**, and iCloud Mail's Sent Messages folder in the app then listed exactly one
  copy, but only after the list was pulled down
  ([#2454](https://github.com/unwired-dev/product/issues/2454)). A message from Seznam
  Email carried a `Date` header 12 seconds before its SMTP submission, consistent with
  the 10-second Undo Send Window. Afterwards no run message remained in any folder of
  either mailbox. Limitations: the first message stayed **Waiting to send**
  because `claimDraftDelivery` failed as unavailable. The development Convex deployment
  ran functions older than the app, and their validators rejected the
  `productAccountId` and `mailProfileCapability` arguments. After those functions were
  pushed, the row was delivered and the Private Sync pull failures of the record above
  stopped ([#2390](https://github.com/unwired-dev/product/issues/2390)). **Undo** itself
  and Delivery unknown were not exercised. Mac, iPad, attachments, organizing, search,
  IDLE, relaunch and recovery stay on #632.
- **2026-11-19, iPhone organize and search
  ([#2458](https://github.com/unwired-dev/product/issues/2458)).** Target, toolchain and
  operator as in the first record, on a new iPhone 18 Pro Simulator on iOS 27.0. Build:
  the app source of `2b6b0a2081d0b149db16bbede517c29cff5898db`. Both certification
  mailboxes were connected through the app as in the first record, and each Inbox
  received one test message from the other mailbox. Result: pass. Each step below was
  checked on the server over IMAP as well as in the app. In each mailbox, the row menu's
  **Mark as unread** cleared the message's `\Seen` flag and **Mark as Read** set it.
  **Move to** a folder without a role (iCloud Mail's unmarked `Archive`, Seznam Email's
  `newsletters`) moved the message there and **Undo** moved it back to the Inbox. iCloud
  Mail offers UIDPLUS without MOVE, so the app moved its messages with `UID COPY` and
  `UID EXPUNGE`. Seznam Email offers MOVE, so the app used `UID MOVE`. **Delete** moved the message to the Trash-role folder
  (`Deleted Messages`, `trash`), and **Move to Inbox** in the Trash view brought it back.
  Seznam Email declares `\Archive` and `\Junk`: the row menu's **Archive** moved the
  message to `archive`, the Command Palette's **Move to Spam** moved it to `spam`, and
  each **Undo** brought it back. iCloud Mail declares neither role, and no Spam folder
  was chosen. Its row menu and reader offered no Archive or Move to Spam, and the Command
  Palette showed Archive as not available and listed no Move to Spam. **Search Mail
  Servers** listed the Inbox copies saved on the device. Under **From mail servers** it
  also listed a message from each mailbox that had been appended over IMAP to a folder
  without a role and was never saved on the device. Afterwards no run message remained
  in any folder of either mailbox. Limitations: Mac, iPad, attachments, the star, IDLE,
  offline queueing, uncertain-move recovery, relaunch and large-folder backfill stay on
  #632.
- **2026-11-20, iPhone attachments
  ([#2471](https://github.com/unwired-dev/product/issues/2471)).** Target, toolchain and
  operator as in the first record, on a new iPhone 18 Pro Simulator on iOS 27.0. Build:
  the app source of `594c5a152f12ffd59a8ff56ff3a95b5e0313a91c`. Both certification
  mailboxes were connected through the app as in the first record. Attachment: one PNG
  image (`image/png`, 146,436 bytes, listed as 143 KB), added with the composer's
  **Attach Photo**. Result: pass. From each mailbox, a new message with the attachment
  went through the Outbox, iCloud Mail over `smtp.mail.me.com` 587 (STARTTLS) and Seznam
  Email over `smtp.seznam.cz` 465 (SSL/TLS), and arrived in the other mailbox. Over IMAP,
  `imap.mail.me.com` 993 and `imap.seznam.cz` 993 (TLS), the delivered message and the
  sender's Sent copy each carried one attachment part with the same file name, content
  type, decoded size and SHA-256 prefix (first 16 hex digits). In each receiving
  mailbox, the reader listed the attachment with its name and size, **Download** saved a
  file with the same size and prefix and **Open** showed it in Quick Look. **Reply** ›
  **Forward** then carried the attachment back to the other mailbox, and the delivered
  forward and its Sent copy had the same decoded size and prefix. Afterwards no run
  message remained in any folder of either mailbox.
  Limitations: once, Forward after **Download**, **Open** and closing the preview showed
  the attachment as **Not added: the file could not be read or saved**, and repeating the
  steps carried it. In the same reader the first **Open** showed no preview and the row
  returned to **Download** ([#2480](https://github.com/unwired-dev/product/issues/2480)).
  The first forward from iCloud Mail was sent, but its server copies were removed before
  they were checked, so the verified forward in that direction came from a second test
  message from Seznam Email. The machine was under heavy load: typed text dropped
  characters and Quick Look took many seconds to appear. Mac, iPad, Share and Save to
  Files ([#2469](https://github.com/unwired-dev/product/issues/2469)), inline images,
  attachments over the 25 MiB download limit, IDLE, relaunch and recovery stay on #632.
- **2026-11-20, iPhone IDLE freshness and relaunch
  ([#2491](https://github.com/unwired-dev/product/issues/2491)).** Target, toolchain and
  operator as in the first record, on a new iPhone 18 Pro Simulator on iOS 27.0. Build:
  the app source of `e7dd19fc4aac8c2405510201b841454d9080f0b1`. The certification
  Product Account was unlocked on this device with its Recovery Key, and both
  certification mailboxes were connected through the app as in the first record. Test
  messages were submitted between the two mailboxes over SMTP from outside the app, and
  each arrival time was read on the server as the message's IMAP `INTERNALDATE`. Result:
  pass. With the app active on All Inboxes, three messages submitted to iCloud Mail,
  which offers IDLE, appeared in the list without pulling it down, 5 to 10 seconds after
  they arrived on `imap.mail.me.com` 993 (TLS). A message submitted to Seznam Email,
  which does not offer IDLE, appeared about three minutes after it arrived on
  `imap.seznam.cz` 993 (TLS), with no interaction, as the five-minute poll allows.
  Another message appeared 12 seconds after the pull-down began, about two and a half
  minutes after its arrival. The app was then terminated, and a message was submitted to
  each mailbox while it was not running. After launch, both connections opened without
  asking for a password, Email Accounts showed each as **Updated just now**, the Inbox
  listed the earlier messages, and both new messages appeared 21 seconds after launch. A
  message submitted to iCloud Mail after the relaunch appeared 5 seconds after it
  arrived, consistent with a resumed IDLE wait. Afterwards no run message remained in
  any folder of either mailbox. Limitations: the delays include up to about 4 seconds
  between the operator's checks of the screen. Mac, iPad, background refresh and push
  wakes, IDLE interruption, password and connection recovery, offline queueing and
  large-folder backfill stay on #632.
- **2026-11-20, iPad connect, read, send and reply
  ([#2510](https://github.com/unwired-dev/product/issues/2510)).** Target: Expo client,
  Release build without a Mock Mail Session, a new iPad Pro 11-inch (M5) Simulator on iOS
  27.0, with the development Convex deployment. Build: the app source of
  `f065fdff4d670ced0e31a389a9f714d7357e3de5`. Toolchain: Xcode 27.2 (27B52). Operator:
  agent, with credentials read at run time from the approved password manager. Result:
  pass. Google Product Sign-In found the certification Product Account, and this device
  was unlocked with its Recovery Key. **iCloud Mail** connected with the app-specific
  password over `imap.mail.me.com` 993 (TLS) and `smtp.mail.me.com` 587 (STARTTLS).
  **Add an IMAP Mailbox** › **Other IMAP Account** then filled in `imap.seznam.cz` 993
  (TLS) and `smtp.seznam.cz` 465 (SSL/TLS) from the catalog for the Seznam Email address,
  and that mailbox connected with its mail-client password. After **Connect**, Email
  Accounts listed each mailbox as **Updated just now**. Before the mailboxes were
  connected, one test message was submitted over SMTP from each mailbox to the other.
  Each Inbox listed real messages, and the test message opened
  in the reader beside the list in each mailbox, which set its `\Seen` flag on the server.
  A new message from iCloud Mail showed **Sending soon** with **Undo**, then **Sending…**
  and **Sent. Saving a copy to Sent…**. The row then left the Outbox, and the message
  appeared in the Seznam Email Inbox in the app. A reply from Seznam Email showed **Sending
  soon** with **Undo**, then **Sent. Saving a copy to Sent…**, left the Outbox and
  appeared in the iCloud Mail Inbox in the app. Over IMAP, its `In-Reply-To`
  named the original's Message-ID and its `References` included it. Each sending
  mailbox's Sent folder held exactly one copy, with the same Message-ID as the delivered
  message, and the app listed that one copy in each Sent folder. Afterwards no run
  message remained in any folder of either mailbox. Limitations: the first recipient
  typed in the composer opened the system Contacts access prompt, which interrupted the
  address. Contacts access was then denied from the operator's tools, which ended the
  app. After launch the composer offered to restore the unsaved message, and the
  restored message was completed and sent. After the first tap on the reply's **Send**, no
  Outbox row appeared for 20 seconds; a second tap sent it. It was not tried again
  ([#2512](https://github.com/unwired-dev/product/issues/2512)). Mac, iPad organizing, search,
  attachments, IDLE and relaunch, recovery and large-folder backfill stay on #632.
- **2026-11-20, iPad organize and search
  ([#2548](https://github.com/unwired-dev/product/issues/2548)).** Target, toolchain and
  operator as in the record above, on a new iPad Pro 11-inch (M5) Simulator on iOS 27.0.
  Build: the app source of `fe1eee44ac0554b3dd8df37025e844adbb331585`. Google Product
  Sign-In found the certification Product Account, this device was unlocked with its
  Recovery Key, and both certification mailboxes were connected through the app as in
  the record above. Before they were connected, one test message was submitted over SMTP
  from each mailbox to the other. Result: pass. Each step below was checked on the
  server over IMAP as well as in the app. In each mailbox, the row menu's **Mark as
  Read** set the message's `\Seen` flag and **Mark as Unread** cleared it. The reader's
  **Folders** moved the message to a folder without a role (iCloud Mail's unmarked
  `Archive`, Seznam Email's `newsletters`), and **Undo** moved it back to the Inbox. iCloud
  Mail offers UIDPLUS without MOVE, so the app's move path there is `UID COPY` with
  `UID EXPUNGE`, and the message came back to the Inbox under a new UID. Seznam Email offers
  MOVE, so its path is `UID MOVE`. The paths follow from each server's capabilities; the
  IMAP commands themselves were not captured. The row menu's **Delete**
  moved the message to the Trash-role folder (`Deleted Messages`, `trash`), and **Move to
  Inbox** in the row menu of the Trash view brought it back. Seznam Email declares
  `\Archive` and `\Junk`: the row menu's **Archive** moved the message to `archive`, the
  Command Palette's **Move to Spam** moved it to `spam`, and each **Undo** brought it back.
  iCloud Mail declares neither role, and no Spam folder was chosen. Its row menu offered
  only Mark as Read or Mark as Unread, Pin and Delete, the reader's toolbar and **More**
  menu offered no Archive or Move to Spam, and the Command Palette showed Archive as not
  available and listed no Move to Spam. In All Inboxes, **Top Results** listed the two
  Inbox test messages known on the device, one with its body saved and one marked to
  download from the mail server when opened. **Search Mail Servers** then listed, under **From mail
  servers**, a message from each mailbox that had been appended over IMAP to a folder
  without a role and was never saved on the device, and each opened in the reader.
  Afterwards no run message remained in any folder of either mailbox. Limitations: while
  the Search field had focus, the first tap on **Search Mail Servers** only ended editing
  and started no search. The next tap started it. This happened on two attempts
  ([#2549](https://github.com/unwired-dev/product/issues/2549)). Mac, iPad attachments,
  the star, IDLE and relaunch, offline queueing, uncertain-move recovery and large-folder
  backfill stay on #632.
- **2026-11-20, iPad attachments
  ([#2567](https://github.com/unwired-dev/product/issues/2567)).** Target, toolchain and
  operator as in the iPad connect record, on a new iPad Pro 11-inch (M5) Simulator on iOS
  27.0. Build: the app source of `6322b2a96c20a65e815c44d16c8f4960341a5088`. Google
  Product Sign-In found the certification Product Account, this device was unlocked with
  its Recovery Key, and both certification mailboxes were connected through the app as in
  the iPad connect record. Attachment: one synthetic PNG image (`image/png`, 173,158 bytes,
  shown as `169,1 KB` in the simulator's Czech region format), added with the composer's
  **Attach Photo**. Result: pass. From each mailbox, a new message with the attachment
  went through the Outbox and arrived in the other mailbox. The connections send through
  `smtp.mail.me.com` 587 (STARTTLS) and `smtp.seznam.cz` 465 (SSL/TLS). Over
  IMAP, `imap.mail.me.com` 993 and `imap.seznam.cz` 993 (TLS), the delivered message and
  the sender's single Sent copy each carried one attachment part with the source file's
  name, content type, decoded size and SHA-256 prefix (first 16 hex digits). In each
  receiving mailbox, the reader beside the list showed the attachment with its name and
  size, **Download** saved a file with the same size and prefix, and **Open** showed it
  in Quick Look. After the preview was closed, the reader's **Forward** listed the
  attachment in the composer and carried it back to the other mailbox. The delivered
  forward and its single Sent copy had the same decoded size and prefix. Afterwards no run
  message remained in any folder of either mailbox. Limitations: Contacts access was
  denied before composing, so the system prompt of the iPad connect record did not
  appear. Mac, Share and Save to Files
  ([#2469](https://github.com/unwired-dev/product/issues/2469)), inline images,
  attachments over the 25 MiB download limit, IDLE and relaunch on iPad, recovery and
  large-folder backfill stay on #632.
- **2026-11-20, iPad IDLE freshness and relaunch
  ([#2569](https://github.com/unwired-dev/product/issues/2569)).** Target, toolchain and
  operator as in the iPad connect, read, send and reply record, on a new iPad Pro 11-inch
  (M5) Simulator on iOS 27.0. Build: the app source of
  `21ef44a3e4aee37dfd5fc5d9ed98758af6071e4a`. Google Product Sign-In found the
  certification Product Account, this device was unlocked with its Recovery Key, and both
  certification mailboxes were connected through the app as in that record. Test messages
  were submitted between the two mailboxes over SMTP from outside the app, and each arrival
  time was read on the server as the message's IMAP `INTERNALDATE`. Result: pass. With the
  app active on All Inboxes, three messages submitted to iCloud Mail, which offers IDLE,
  appeared in the list without pulling it down, 5 to 6 seconds after they arrived on
  `imap.mail.me.com` 993 (TLS). A message submitted to Seznam Email, which does not offer
  IDLE, appeared 3 minutes 17 seconds after it arrived on `imap.seznam.cz` 993 (TLS), with
  no interaction, as the five-minute poll allows. Another was still not listed 37 seconds
  after its arrival and appeared 9 seconds after a pull-down began. The app was then
  terminated, and a message was submitted to each mailbox while it was not running. After
  launch, both connections opened without asking for a password, the Inbox listed the
  earlier run messages, and both new messages appeared 13 seconds after launch. A message
  submitted to iCloud Mail after the relaunch appeared 4 seconds after it arrived,
  consistent with a resumed IDLE wait, and Email Accounts then showed each mailbox as
  **Updated just now**. Afterwards no run message remained in any folder of either mailbox.
  Limitations: the delays include up to a few seconds between the operator's checks of the
  screen. While setting up, the first tap on **Connect** in the iCloud Mail form, with the
  Password field focused, did nothing, and the second tap connected
  ([#2571](https://github.com/unwired-dev/product/issues/2571)). Mac,
  background refresh and push wakes, IDLE interruption, password and connection recovery,
  offline queueing and large-folder backfill stay on #632.
- **2026-11-20, Mac connect, read, send and reply
  ([#2579](https://github.com/unwired-dev/product/issues/2579)).** Target: React Native
  macOS client, development-signed Release build without a Mock Mail Session, on macOS
  27.2.1, with the development Convex deployment. Build: the app source of
  `768201e1362cda75292a6941c56602d82d95b6aa`. Toolchain: Xcode 27.2 (27B52). Operator:
  agent, with credentials read at run time from the approved password manager. Result:
  pass. **Sign in with Google** first showed the system prompt that the app wants to use
  `accounts.google.com` to sign in, then opened Google's sign-in page in the Mac's default
  browser. Product Sign-In found the certification Product Account, and the Mac was
  unlocked with its Recovery Key. **iCloud Mail** connected with the app-specific password
  over `imap.mail.me.com` 993 (TLS) and `smtp.mail.me.com` 587 (STARTTLS). Settings ›
  Email Accounts › **Add an IMAP Mailbox** › **Other IMAP Account** then filled in
  `imap.seznam.cz` 993 (TLS) and `smtp.seznam.cz` 465 (SSL/TLS) from the catalog for the
  Seznam Email address, and that mailbox connected with its mail-client password. Each
  mailbox was listed only after its **Connect**. Before the mailboxes were connected, one
  test message was submitted over SMTP from each mailbox to the other. Each Inbox listed
  real messages, and the test message opened in the reader beside the list in each
  mailbox, which set its `\Seen` flag on the server. A new message from iCloud Mail waited
  in the Outbox for its Undo Send Window and arrived on `imap.seznam.cz` 16 seconds after
  **Send**. It was not yet listed in the Seznam Email Inbox in the app at a check about
  40 seconds after it arrived, and appeared after **View › Refresh**. A reply from Seznam Email showed **Sending soon** with
  **Undo** in the Outbox, left it, arrived on `imap.mail.me.com` 19 seconds after **Send**,
  and was listed in the iCloud Mail Inbox in the app without a refresh. Over IMAP, its
  `In-Reply-To` named the original's Message-ID and its `References` included it. Each
  sending mailbox's Sent folder held exactly one copy, with the same Message-ID as the
  delivered message, and the app listed that one copy in each Sent folder. Afterwards no
  run message remained in any folder of either mailbox, and **Sign Out of This Device**
  removed the account from the Mac and returned it to Welcome. Limitations: the first
  launch restored two Inbox windows, and one was closed before sign-in. The operator drove the app through the macOS
  accessibility interface and synthesized keyboard and mouse input. For the first
  message only the Outbox entry was checked, not its row text. Mac organizing, search,
  attachments, IDLE and relaunch, recovery and large-folder backfill stay on #632.
- **2026-11-21, Mac organize and search
  ([#2585](https://github.com/unwired-dev/product/issues/2585)).** Target, toolchain and
  operator as in the record above. Build: the app source of
  `c55b27879524e52f026f81db368b1d6114fdcaa9`. Google Product Sign-In found the
  certification Product Account, the Mac was unlocked with its Recovery Key, and both
  certification mailboxes were connected through the app as in the record above. Before
  they were connected, one test message was submitted over SMTP from each mailbox to the
  other. Result: pass. Each step below was checked on the server over IMAP as well as in
  the app. In each mailbox, the row menu's **Mark as Read** set the message's `\Seen` flag
  and **Mark as Unread** cleared it. The reader's **Folders** moved the message to a folder
  without a role (iCloud Mail's unmarked `Archive`, Seznam Email's `newsletters`), and
  **Undo** moved it back to the Inbox under a new UID. iCloud Mail offers UIDPLUS without
  MOVE, so the app's move path there is `UID COPY` with `UID EXPUNGE`; Seznam Email offers
  MOVE, so its path is `UID MOVE`. The paths follow from each server's capabilities; the
  IMAP commands themselves were not captured. The row menu's **Delete** moved the message
  to the Trash-role folder (`Deleted Messages`, `trash`), and **Move to Inbox** in the row
  menu of the Trash view, which offered no Delete, brought it back. Seznam Email declares
  `\Archive` and `\Junk`: the row menu's **Archive** moved the message to `archive`, the
  reader's **Move to Spam** moved it to `spam`, and each **Undo** brought it back. iCloud
  Mail declares neither role, and no Spam folder was chosen. Its row menu offered only
  Mark as Read or Mark as Unread, Pin and Delete, the reader's toolbar offered no Archive
  or Move to Spam, and the Command Palette showed Archive as not available and found no
  command for "spam". After those steps, one message was appended over IMAP to the same
  folder without a role in each mailbox. A search for a word only in their subjects found
  no saved mail in All Inboxes, a search that covers only the Inbox copies saved on the
  device; whether the app had saved those two folders was not checked. **Search Mail
  Servers** then listed both under **From mail servers**, from the servers; each opened in the reader with its text. Afterwards no run message
  remained in any folder of either mailbox, **Sign Out of This Device** removed the
  account's keys, Keychain records and mailbox access from the Mac and returned the app to
  Welcome, and the run's caches, HTTP storage and saved window state were removed from
  the app's container. Limitations: the system prompt for Contacts access appeared during
  sign-in and was denied; the app kept running. The operator drove the app through the
  macOS accessibility interface and synthesized keyboard and mouse input. Mac attachments,
  the star, IDLE and relaunch, offline queueing, uncertain-move recovery and large-folder
  backfill stay on #632.
- **2026-11-21, Mac attachments
  ([#2601](https://github.com/unwired-dev/product/issues/2601)).** Target, toolchain and
  operator as in the Mac connect record. Builds: the app source of
  `d7bd6304c782e76926251369a23b5b94b1ea8990`, then the same source with the fixes for
  [#2603](https://github.com/unwired-dev/product/issues/2603) and
  [#2604](https://github.com/unwired-dev/product/issues/2604), and last the app source of
  `47ee9c935ed51347a43dbc444537fc456c69b65a`, which also downloads the file for Attach to
  New Message only after leaving an open composer. Google Product Sign-In
  found the certification Product Account, the Mac was unlocked with its Recovery Key,
  and both certification mailboxes were connected through the app as in the Mac connect
  record. Attachment: one synthetic PNG image (`image/png`, 153,873 bytes, shown as
  `150,3 KB` in the Mac's Czech region format), added with the composer's paperclip
  through the system open panel. Result: pass with the fixes. From each mailbox, a new
  message with the attachment went through the Outbox and arrived in the other mailbox.
  Over IMAP, `imap.mail.me.com` 993 and `imap.seznam.cz` 993 (TLS), the delivered message
  and the sender's single Sent copy each carried one attachment part with the source
  file's name, content type, decoded size and SHA-256 prefix (first 16 hex digits). In
  each receiving mailbox, the reader listed the attachment with its name and size, and
  **Download** offered **Open**, **Share** and **Attach to New Message**; in Seznam Email
  the saved file had the same size and prefix. On the first build, **Open** showed
  nothing (#2603). After the Mac switched to another app and back, Forward marked the
  attachment **Not added: the file could not be read or saved**, and Attach to New
  Message did nothing (#2604). With the fixes, **Open** showed the image in the Quick Look
  panel. After a switch to Finder and back, the reader's **Forward** from Seznam Email
  downloaded the file again and carried it to iCloud Mail. The delivered forward and its
  single Sent copy had the same decoded size and prefix. On the last build, one more
  message with the same attachment, submitted over SMTP from Seznam Email, was opened in
  iCloud Mail: **Download** saved it, **Open** showed the image in the Quick Look panel,
  and after a switch to Finder and back **Forward** carried it to Seznam Email, where the
  delivered forward and iCloud Mail's single Sent copy had the same decoded size and
  prefix. After another switch, Attach to New Message started a Draft listing the file at
  its size. Each Draft from Attach to New Message was discarded unsent, as were the
  Drafts the failed forwards had left. Afterwards no
  run message remained in any folder of either mailbox, **Sign Out of This Device**
  returned the app to Welcome, and the run's caches and HTTP storage were removed from
  the app's container. Limitations: the operator drove the app through the macOS
  accessibility interface and synthesized keyboard and mouse input, and saw the Quick
  Look panel in a window capture. Seznam Email was not connected for the last build's
  checks. **Share**, Save to Downloads ([#1681](https://github.com/unwired-dev/product/issues/1681)),
  inline images, attachments over the 25 MiB download limit, the star, IDLE and
  relaunch, offline queueing, recovery and large-folder backfill stay on #632.
- **2026-11-21, Mac IDLE freshness and relaunch
  ([#2620](https://github.com/unwired-dev/product/issues/2620)).** Target, toolchain and
  operator as in the Mac connect record. Build: the app source of
  `9dd8ef3f828424802b9d487d43e385e0cb80df46`. Google Product Sign-In found the
  certification Product Account, the Mac was unlocked with its Recovery Key, and both
  certification mailboxes were connected through the app as in the Mac connect record.
  Test messages were submitted between the two mailboxes over SMTP from outside the app,
  and each arrival time was read on the server as the message's IMAP `INTERNALDATE`.
  Result: pass. With the app active on All Inboxes, three messages submitted to iCloud
  Mail, which offers IDLE, appeared in the list without **View › Refresh**, 16, 6 and 6
  seconds after they arrived on `imap.mail.me.com` 993 (TLS). A message submitted to
  Seznam Email, which does not offer IDLE, appeared 3 minutes 4 seconds after it arrived
  on `imap.seznam.cz` 993 (TLS), with no interaction, as the five-minute poll allows.
  Another was still not listed 32 seconds after its arrival and was first seen 10
  seconds after **View › Refresh**. The app was then quit, and a message was submitted to
  each mailbox while it was not running. After launch, one Inbox window opened, both
  connections opened without asking for a password, and the Inbox listed the earlier run
  messages; the new iCloud Mail message was listed 12 seconds after launch and the new
  Seznam Email message by 17 seconds, at the first check for it. A message submitted to
  iCloud Mail after the relaunch appeared 9 seconds after it arrived, consistent with a
  resumed IDLE wait. Email Accounts then listed both mailboxes as connected. Afterwards
  no run message remained in any folder of either mailbox, **Sign Out of This Device**
  returned the app to Welcome, and the run's caches and HTTP storage were removed from
  the app's container. Limitations: the operator drove the app through the macOS
  accessibility interface and synthesized keyboard and mouse input, and checked the list
  every 3 to 4 seconds while waiting for a message, so those delays include up to that
  much. A first **Sign in with
  Google** pressed through accessibility while the app was not the active application
  failed with "Setup could not finish"; pressed again with the app active, it showed the
  system prompt. The Keychain records were not inspected directly. In Email Accounts, the
  second mailbox's **Enter the Password…** and **Remove…** buttons carried the first
  mailbox's address in their accessibility labels
  ([#2621](https://github.com/unwired-dev/product/issues/2621)). Background refresh and
  push wakes, IDLE interruption, password and connection recovery, offline queueing and
  large-folder backfill stay on #632.
- **2026-11-21, iPhone large-folder history
  ([#2623](https://github.com/unwired-dev/product/issues/2623)).** Target, toolchain and
  operator as in the first record, on a new iPhone 18 Pro Simulator on iOS 27.0. Build:
  the app source of `6ca5b03971c45c2318e8ddc6d4d01ae70d067e02`. Before the app connected,
  a run folder of 1,500 small synthetic messages was appended over IMAP to each
  certification mailbox, with no SMTP submission. Read over IMAP before the app connected,
  the server counted 1,501 messages across iCloud Mail's selectable folders and 1,502
  across Seznam Email's. Google Product Sign-In found the certification Product Account,
  the device was unlocked with its Recovery Key, and both mailboxes were connected through
  the app as in the first record. Result: partial. The totals matched the server, Seznam
  Email resumed after termination, and both histories completed as far as the app shows;
  the final downloaded counts are not shown on iPhone. **iCloud Mail**: about 25 seconds
  after **Connect**, Sync Status showed **Downloading history · 1,001 of 1,501
  messages**, and the capsule had faded about a minute after connecting. **Seznam
  Email**: when the Inbox was opened, about a minute after connecting, its capsule had
  already faded. The app was then terminated, a second run folder of 6,000 messages was
  appended to Seznam Email, and the server counted 7,502 messages across its selectable
  folders. The app was launched again, and both connections opened without asking for a
  password. Sync Status showed Seznam Email's **1,502 messages** already downloaded until
  the new folder began, then **2,002 of 7,502 messages** 23 seconds after launch, when
  the app was terminated. Launched again, it showed **2,002 of 7,502 messages** at its
  first reading, 8 seconds after launch, and a message opened in the reader while the
  download continued. The next check, about 11 minutes after that launch, found the
  capsule faded, and a further launch showed each connection checking its server and then
  up to date, with no history download. The Mailboxes list showed the three run folders.
  Afterwards the run folders were deleted from both mailboxes, and an IMAP count then
  found each mailbox's original totals; the run folders were not counted again between
  the download and their deletion. The simulator was deleted. Limitations: the iCloud Mail download and
  the first Seznam Email download finished too quickly to interrupt, so resumption after
  termination was observed for Seznam Email only. Sync Status closes with the capsule and
  shows no completed history, so no final downloaded count was on screen: completion is
  read from the capsule fading and from the next launch downloading nothing. The resumed
  download's duration is not known. As in the iPad record, the first tap on **Connect**
  with a field focused did nothing
  ([#2571](https://github.com/unwired-dev/product/issues/2571)). iCloud Mail resumption
  after termination, iPad and Mac backfill, background refresh and push wakes, IDLE
  interruption, password and connection recovery and offline queueing stay on #632.
- **2026-11-21, Mac large-folder history
  ([#2627](https://github.com/unwired-dev/product/issues/2627)).** Target, toolchain and
  operator as in the Mac connect record. Build: the app source of
  `818137bf6b0f643e3649fd7809872a5058dc6d61`. Before the app connected, a run folder of
  6,000 small synthetic messages was appended over IMAP to each certification mailbox,
  with no SMTP submission. Read over IMAP before the app connected, the server counted
  6,001 messages across iCloud Mail's selectable folders and 6,002 across Seznam Email's.
  Google Product Sign-In found the certification Product Account, and the Mac was unlocked
  with its Recovery Key. Result: partial. Each mailbox resumed after the app was quit,
  both histories completed, and a message opened in the reader during a download. No
  sampled iCloud Mail row showed a total, so that check stays outstanding. Times below are
  the operator's one-second Sync Status readings. **iCloud Mail** connected over
  `imap.mail.me.com` 993 (TLS). Sync Status showed **Downloading history · 5,001
  messages** at its first reading, 51 seconds after **Connect**, and **6,001 messages** 7
  seconds later; the capsule faded 2 seconds after that, too soon to quit the app.
  **Seznam Email** was then added in **Settings › Email Accounts** over `imap.seznam.cz`
  993 (TLS). Sync Status showed **Downloading history · 502 of 6,002 messages** 12 seconds
  after **Connect**, and the app was quit with **Quit Unwired Mail** at **1,502 of
  6,002**, 14 seconds after **Connect**. Launched again 9 seconds later, the app opened
  both connections without asking for a password, and Sync Status showed **1,502 of
  6,002** at its first reading, 7 seconds after launch, then **6,002 of 6,002** 25 seconds
  after launch, and the capsule faded. To interrupt iCloud Mail, the operator removed its
  connection with **Remove…** in Email Accounts and connected it again, entering its
  password in the connect form. Reconnecting started a fresh backfill, and the operator
  quit the app at **1,501 messages**, about 28 seconds after **Connect**. Launched again,
  the app showed **1,501 messages** at its first reading, about 7 seconds after launch,
  without asking for a password. An iCloud Inbox message opened in the reader with its
  body, with remote images held back, while the download continued; Sync Status first read
  **6,001 messages** about 45 seconds after launch, and the capsule faded. On a further
  launch, Sync Status showed each connection checking its mail server and then nothing for
  the next minute: no history download. Read over IMAP after the app run, the server still
  counted 6,001 and 6,002 messages, and the Mailboxes list showed both run folders.
  Afterwards the run folders were deleted from both mailboxes, and an IMAP count then
  found each mailbox's original totals. **Sign Out of This Device** returned the app to
  Welcome, and the run's caches and HTTP storage were removed from the app's container.
  Limitations: Sync Status shows a connection's total only once every folder has begun. No
  sampled iCloud Mail row showed a total. iCloud Mail lists the run folder before its Sent
  and Drafts folders and Seznam Email lists it last, which may explain the difference, but
  the run did not confirm it. As on iPhone, Sync Status closes with the capsule, so
  completion is read from the capsule fading and from the next launch downloading nothing.
  iCloud Mail's resume was measured on the second, fresh backfill after its connection was
  removed and connected again. Readings were sampled about once a second, so the times are
  approximate. The Sync Status readings and server counts were captured by the operator's
  scripts; Product Sign-In, the Recovery Key unlock, sign-out and the container cleanup
  are operator observations without a captured record. The operator drove the app through
  the macOS accessibility interface and synthesized keyboard and mouse input. As in the
  Mac IDLE record, the first **Sign in with Google** failed with "Setup could not finish",
  and a second press showed the system prompt. The Keychain records were not inspected
  directly. After the reconnection, iCloud Mail's row read **Downloading history · 1
  messages** for about 8 seconds
  ([#2642](https://github.com/unwired-dev/product/issues/2642)). iPad backfill, iCloud
  Mail resumption on iPhone, background refresh and push wakes, IDLE interruption,
  password and connection recovery and offline queueing stay on #632.
- **2026-11-22, iPad large-folder history
  ([#2653](https://github.com/unwired-dev/product/issues/2653)).** Target, toolchain and
  operator as in the iPad connect, read, send and reply record, on a new iPad Pro 11-inch
  (M5) Simulator on iOS 27.0. Build: the app source of
  `8e00476e70cd4acf07e55265c6c9693cd7a58f54`. Before the app connected, a run folder of
  6,000 small synthetic messages was appended over IMAP to each certification mailbox,
  with no SMTP submission. Read over IMAP before the app connected, the server counted
  6,001 messages across iCloud Mail's selectable folders and 6,002 across Seznam Email's.
  Google Product Sign-In found the certification Product Account, the device was unlocked
  with its Recovery Key, and both mailboxes were connected through the app as in that
  record. Result: pass. Each total matched the server, each mailbox resumed after
  termination without asking for a password, both histories completed, and messages opened
  in the reader during a download. Times below come from the operator's one-second Sync
  Status readings. **iCloud Mail** connected over `imap.mail.me.com` 993 (TLS), and Sync
  Status showed **Downloading history · 4,001 of 6,001 messages** about 45 seconds after
  **Connect**. **Seznam Email** was then added over `imap.seznam.cz` 993 (TLS). Its first
  download was not watched. With the app terminated, a second run folder of 6,000 messages
  was appended, and the server counted 12,002 messages. After launch, Sync Status showed
  **6,002 messages** until the new folder began, then **6,502 of 12,002**, and **12,002 of
  12,002** 35 seconds after launch. With the app terminated again, a third run folder of
  12,000 messages was appended, and the server counted 24,002. After launch, Sync Status
  showed **12,002 messages**, then **12,502 of 24,002** 25 seconds after launch, when the
  app was terminated. Launched again, it opened both connections without asking for a
  password, showed **12,502 of 24,002** at its first reading 8 seconds after launch, and
  reached **24,002 of 24,002** 46 seconds after launch. To interrupt iCloud Mail, the
  operator removed its connection with **Remove…** in Email Accounts and connected it
  again, entering its password in the connect form, which started a fresh backfill. The
  app was terminated 32 seconds after **Connect**, while the capsule read **Updating 1
  account · 25%**. Launched again, it showed **1,501 of 6,001** at its first reading 7
  seconds after launch, without asking for a password. It read **5,501 of 6,001** 40
  seconds after launch, and then Sync Status closed as the capsule faded. On a further
  launch, Sync Status showed each connection checking its mail server and then nothing for
  the next 40 seconds: no history download. Read over IMAP after the app run, the server
  counted 6,001 and 24,002 messages, and the Mailboxes list showed every run folder. For
  the reader check, a second new iPad Simulator was set up the same way with only Seznam
  Email and a 12,000-message run folder; the server counted 12,002. After that connection
  was removed and connected again, a message was tapped 24 seconds after **Connect**, and
  3 seconds later the reader showed its body while the capsule read **Updating 1 account ·
  45%**. A second message, tapped 5 seconds after the first, showed its body at **58%**,
  and the capsule faded within 20 seconds. Afterwards the run folders were deleted from
  both mailboxes, an IMAP count found each mailbox's original totals, and both simulators
  were deleted. Limitations: as on iPhone and the Mac, Sync Status closes with the
  capsule, so iCloud Mail's final count of 6,001 was not on screen; its completion comes
  from the capsule fading and the next launch downloading nothing. iCloud Mail's resume
  was measured on the second, fresh backfill after its connection was removed and
  connected again. That termination point comes from the capsule's percentage in a
  screenshot, because the operator's accessibility reads stalled while the app downloaded.
  The first iCloud Mail run was terminated after a last reading of **5,501 of 6,001**, but
  its readings after relaunch were not captured, so that run is not counted. Seznam Email
  was interrupted in its third run folder, and its first download was not watched. Before
  Seznam Email first connected, one attempt stayed on **Checking the mail server…** and
  the operator removed it. It did not happen again in later connects, and the cause was
  not found ([#2659](https://github.com/unwired-dev/product/issues/2659)). Readings were
  sampled about once a second, so the times are approximate. As in the iPad IDLE record,
  one tap on **Connect** with the keyboard showing did nothing
  ([#2571](https://github.com/unwired-dev/product/issues/2571)). In Email Accounts, an
  IMAP connection's row wraps its address a few characters per line
  ([#2658](https://github.com/unwired-dev/product/issues/2658)). iCloud Mail resumption on
  iPhone, an iCloud Mail backfill total on the Mac, background refresh and push wakes,
  IDLE interruption, password and connection recovery and offline queueing stay on #632.
- **2026-11-22, iPhone iCloud Mail history resume
  ([#2663](https://github.com/unwired-dev/product/issues/2663)).** Target, toolchain and
  operator as in the first record, on a new iPhone 18 Pro Simulator on iOS 27.0. Build:
  the app source of `9f819a0eb7c0c3e05f80c06caf9a89f16cfbd750`. Before the app
  connected, a run folder of 6,000 small synthetic messages was appended over IMAP to the
  iCloud Mail certification mailbox, with no SMTP submission, and the server counted
  6,001 messages across its selectable folders. Google Product Sign-In found the
  certification Product Account, and the device was unlocked with its Recovery Key.
  Result: pass. iCloud Mail resumed its first download after termination without asking
  for a password and the history completed. A later download, after a second run folder
  was added, showed a total that matched the server, and a message opened in the reader
  during it. Times below come from the operator's
  one-second Sync Status readings. **iCloud Mail** connected over `imap.mail.me.com` 993
  (TLS). Sync Status showed **Downloading history · 1 messages** 19 seconds after
  **Connect** and **1,001 messages** 24 seconds after it, when the app was terminated.
  Launched again, it showed **1,001 messages** at its first reading, 8 seconds after
  launch, and **6,001 messages** 41 seconds after launch; then Sync Status closed as the
  capsule faded. On the next launch, Sync Status showed **Checking the mail server…** and
  then nothing for the next 45 seconds: no history download. With the app open, a second
  run folder of 6,000 messages was copied on the server, which then counted 12,001. After
  a further launch, Sync Status showed **6,001 messages** 10 seconds after launch. An
  Inbox message was tapped 13 seconds after launch, and 3 seconds later the reader showed
  its body, with remote images held back. Sync Status then read **6,501 of 12,001
  messages**, 21 seconds after launch, and **11,501 of 12,001** 47 seconds after launch,
  and the capsule faded. On a final launch, the capsule read **Updating 1 account** and
  then showed no history download for the next 50 seconds. Read over IMAP after the app
  run, the server counted 12,001 messages, and the Mailboxes list showed both run
  folders. Afterwards both run folders were deleted, an IMAP count found the mailbox's
  original folders and total, and the simulator was deleted. Limitations: Sync Status
  shows a total only once every folder has begun, and no sampled reading of the first
  download showed one, so the total was checked in the later download. The first
  download's last reading, **6,001 messages**, equals the server's count; the later
  download was last sampled at **11,501 of 12,001**. As on the other hosts, Sync Status
  closes with the capsule, so completion comes from the capsule fading and the next launch
  downloading nothing. During the first resumed download, the reader check began 9
  seconds after launch and still read **Loading message…** 4 seconds later, when the
  operator went back, so the reader was verified only in the later download. Readings
  were sampled about once a second, so the times are approximate. An earlier attempt on
  another new simulator is not counted: it had no reading before termination. An iCloud Mail
  backfill total on the Mac, background refresh and push wakes, IDLE interruption,
  password and connection recovery and offline queueing stay on #632.
- **2026-11-22, Mac iCloud Mail history total
  ([#2674](https://github.com/unwired-dev/product/issues/2674)).** Target, toolchain and
  operator as in the Mac connect record, on macOS 27.2.1. Build: the app source of
  `b179e944beeadfc1998bd0e93093af210e15182e`. Before the app connected, the iCloud Mail
  certification mailbox held 1 message across its six selectable folders. A run folder
  of 6,000 small synthetic messages was then added over IMAP, with no SMTP submission:
  2,177 appended messages, then copied within the folder on the server, because iCloud
  Mail slowed the appends; copies share their originals' Message-IDs. The server counted
  6,001. Each server count below is the sum of every selectable folder's IMAP message
  count. Google Product Sign-In found the certification Product
  Account, and the Mac was unlocked with its Recovery Key. Result: pass. A later download,
  after a second run folder was added, showed a total that matched the server, a message
  opened in the reader during it, and the history completed. Times below come from the
  operator's Sync Status readings. **iCloud Mail** connected over `imap.mail.me.com` 993
  (TLS). Sync Status showed **Downloading history · 501 messages** 26 seconds after
  **Connect** and **6,001 messages** 54 seconds after it, with no total, and the capsule
  faded 3 seconds later. With the app quit, a second run folder of 6,000 messages was
  copied on the server, which then counted 12,001 across eight folders. Launched again,
  the app showed **Checking the mail server…** 5 seconds after launch and **6,001
  messages** 8 seconds after launch, then **6,501 of 12,001 messages** 20 seconds after
  launch, when the new folder had begun, and **11,501 of 12,001** 50 seconds after launch;
  then Sync Status closed as the capsule faded. An Inbox message was clicked 32 seconds
  after launch, while the capsule read **Updating 1 account · 70%**, and 9 seconds later
  the reader showed its body, with remote images held back, at **83%**. On the next
  launch, Sync Status showed **Checking the mail server…** and then nothing for about
  the next 70 seconds: no history download. Read over IMAP after the app run, the server still
  counted 12,001 messages, and the Mailboxes list showed both run folders. Afterwards both
  run folders were deleted, an IMAP count found the mailbox's original folders and total,
  **Sign Out of This Device** returned the app to Welcome, and the run's caches and HTTP
  storage were removed from the app's container. Limitations: as in the earlier Mac
  record, no sampled reading of the first download showed a total; Sync Status shows one
  only once every folder has begun. As on the other hosts, Sync Status closes with the capsule, so
  the final count of 12,001 was not on screen; completion comes from the capsule fading
  and the next launch downloading nothing. The operator's accessibility reads were
  sampled every 1 to 3 seconds, so the times are approximate. iCloud Mail answered the second folder's copy with NO while it went on filling the folder to 6,000
  over about 3 minutes, and kept that folder at 5,900 messages for over a minute after
  reporting its deletion complete. A second deletion returned `NO [UNAVAILABLE] Internal
  server error`, and the IMAP count that followed found only the original folders. As in the Mac
  IDLE record, the first **Sign in with Google** failed with "Setup could not finish",
  and a second press showed the system prompt. The operator drove the app through the
  macOS accessibility interface and synthesized mouse and keyboard input. Background
  refresh and push wakes, IDLE interruption, password and connection recovery and offline
  queueing stay on #632.
- **2026-11-22, iPhone lost connection to iCloud Mail
  ([#2683](https://github.com/unwired-dev/product/issues/2683)).** Target, toolchain and
  operator as in the first record, on a new iPhone 18 Pro Simulator on iOS 27.0. Build: the
  app source of `c20dc0119168cf59625a5ad97c667de274ead18e`. Google Product Sign-In found the
  certification Product Account, the device was unlocked with its Recovery Key, and both
  certification mailboxes were connected through the app as in the first record. Outage
  method: a temporary rule in the Mac's packet filter, which carries the Simulator's
  traffic, refused TCP to and from `17.0.0.0/8` on ports 993 and 587, which covers every
  address `imap.mail.me.com` and `smtp.mail.me.com` resolved to, in both directions and
  for connections already open. The packet filter was off before the run and was turned
  off again after each outage. In a check before the run, the rule refused a connection to
  `imap.mail.me.com` 993 while `imap.seznam.cz` 993 still connected. Test messages were submitted to iCloud Mail
  over SMTP from Seznam Email outside the app, and each arrival time was read on the
  server as the message's IMAP `INTERNALDATE`. Result: the app's behaviour passed; the
  credential-handling and outage-scope criteria did not (see the limitations). Before any outage, with the
  app active on All Inboxes, a message appeared in the list at most 5 seconds after it
  arrived. **IDLE interruption and offline queueing:** the outage was started with the
  app waiting on iCloud Mail's Inbox. A message submitted 9 seconds later arrived on the
  server 24 seconds after the start and was not listed while the outage lasted. A new
  message from iCloud Mail, sent from the app 10 seconds after the start, left the Undo
  Send Window and waited: the Outbox read **1 waiting**, and its row **Waiting to send.
  It sends when this device can reach the mail server and your Unwired Mail account.**
  The Mailboxes list showed no warning for iCloud Mail during the outage. The outage
  lasted 4 minutes 2 seconds. Without a relaunch or any interaction, the waiting message
  was filed in iCloud Mail's Sent folder 25 seconds after the outage ended and arrived on
  `imap.seznam.cz` a second later. Exactly one copy was in each, with the same
  Message-ID. The list read **Updating 2 accounts** 45 seconds after the outage ended,
  and 2 seconds later listed the message that had arrived during the outage and the sent
  message in the Seznam Email Inbox. Whether that catch-up came from the interrupted IDLE
  wait trying again or from the five-minute poll was not distinguished. A message submitted next appeared 5 seconds after it
  arrived, consistent with a resumed IDLE wait. **Connection recovery:** with a second
  outage in place, the app was terminated and launched again. It opened the Inbox with
  iCloud Mail's saved messages and asked for no password. The list header then read **All
  Inboxes · Offline** with **1 account needs attention** and **Try Again**, and Email
  Accounts showed iCloud Mail as **Saved mail only until the mail server can be checked**
  and Seznam Email as updated just now. A message submitted during this outage arrived on
  the server before it ended. The outage lasted 2 minutes 49 seconds. Without a relaunch
  or any interaction, the list read **Syncing** and then listed that message 2 minutes
  26 seconds after the outage ended, the attention notice was gone, and Email Accounts
  showed iCloud Mail as updated just now. A message submitted next appeared 6 seconds
  after it arrived. Afterwards no run message remained in any folder of either mailbox,
  each mailbox's folder counts matched those before the run, **Sign Out of This Device**
  returned the app to Welcome, and the Simulator was deleted. Limitations: the rule
  covered every Apple address on ports 993 and 587, more than iCloud Mail's two servers,
  and that it closed the already open IDLE connection is inferred from the message not
  being listed during the outage, not observed on the connection. The outage
  cut the path to iCloud Mail's servers on the Mac, so the Simulator kept its own network
  connection and saw no network change, as a device leaving Wi-Fi would. A header of
  **Offline** while Seznam Email was up to date follows the subtitle rule, which names
  Offline when a shown mailbox cannot be reached. The operator's screen readings were
  sampled every 2 to 3 seconds, so the times include up to that much. The XCTest runner
  that drove the Simulator wrote the text it entered, including the passwords and Recovery
  Key, to its own diagnostic log on the Mac, so credentials were written to a log there,
  though not by the app; those files were deleted minutes later, and a scan after the run
  found none left. Background refresh and push wakes,
  password recovery, Seznam Email outages and connection loss on iPad and Mac stay on
  #632.
- **2026-11-22, iPhone credential entry through the pasteboard
  ([#2685](https://github.com/unwired-dev/product/issues/2685)).** Target, toolchain and
  operator as in the first record, on a new iPhone 18 Pro Simulator on iOS 27.0, with
  Simulator closed. Build: the Release app of the #2663 record. Result: the sign-in
  passed and no file this run wrote held a credential, but the Mac was not clean (see
  the limitations). Every credential was entered with pasteboard steps 1 to 3 above, and
  nothing was typed: the Google address and password in the Google sign-in sheet, with
  no paste permission prompt, the Recovery Key, then the iCloud Mail address and
  app-specific password and the Seznam Email address and mail-client password in
  **Connect your mail** and **Other IMAP Account**. Google Product Sign-In found the certification Product Account, **Unlock
  with Recovery Key** unlocked the device, and Email Accounts showed both mailboxes
  **Updated just now**. The Mac's pasteboard did not change. **Sign Out of This Device**
  returned the app to Welcome, and the Simulator was deleted. The scan then covered
  `~/.agent-device`, including this run's runner result bundle, `~/Library/Logs`,
  Xcode's DerivedData, the shell history, the temporary directory, the repository's
  `artifacts`, the operator's scratch files and the agents' session transcripts and
  state on this Mac. No file this run wrote held a password or the Recovery Key.
  Limitations: the scan found the Recovery Key, and in one session the iCloud Mail
  password, in agent session transcripts, their logs and T3 Code's state database,
  all written by earlier runs, the latest about 80 minutes before this one. The scan
  criterion of #2685 waits on their removal and a clean rescan
  ([#2688](https://github.com/unwired-dev/product/issues/2688)).
- **2026-11-23, iPhone lost connection to iCloud Mail, rerun
  ([#2683](https://github.com/unwired-dev/product/issues/2683)).** This rerun repeats the
  three cases of the 2026-11-22 record under a rule narrowed to iCloud Mail's servers
  and with pasteboard credential entry. Target, toolchain and operator as in the first record, on a new iPhone 18 Pro Simulator on
  iOS 27.0, with Simulator closed. Build: the app source of
  `1ac442d43fae08e8ef53bb50e24bc2597f30070d`. Every credential was entered with
  pasteboard steps 1 to 3 above; Google Product Sign-In found the certification Product
  Account, **Unlock with Recovery Key** unlocked the device, and both mailboxes
  connected. Outage method: a temporary anchor in the Mac's packet filter refused TCP to
  and from the addresses `imap.mail.me.com` and `smtp.mail.me.com` resolved to, on ports
  993 and 587 only. The addresses were resolved several times through the Mac's resolver
  and two public resolvers when the rule was loaded and again after a 5-second pause between sweeps while it was
  in place (17 and 18 addresses). Loading the rule also cleared the packet filter's states for those
  addresses, so connections already open passed no more packets. The packet filter was off before the
  run and was turned off again after each outage. During the first counted outage,
  `imap.mail.me.com` 993 and `smtp.mail.me.com` 587 timed out while `imap.seznam.cz` 993
  and `smtp.seznam.cz` 465 connected; during the second, `imap.mail.me.com` 993 timed out
  while `imap.seznam.cz` 993 connected. During both, the packet filter held no state for an
  iCloud Mail address.
  Test messages were submitted to iCloud Mail over SMTP from Seznam Email outside the
  app, and each arrival time was read on the server as the message's IMAP `INTERNALDATE`.
  Result: the three cases and the outage scope passed, and no scanned file this run wrote held a
  credential; the scan still found earlier runs' copies (see below). Before any outage, a message appeared in the list at most 6 seconds after
  it arrived. **IDLE interruption and offline queueing:** the outage was started with All
  Inboxes open and the app's iCloud Mail connection waiting on the Inbox. That connection
  was last sampled open 40 seconds after the start and was gone 43 seconds after. A message submitted 85 seconds after the start arrived
  on the server 20 seconds later and was not listed while the outage lasted. The list
  header read **All Inboxes · Offline** with **1 account needs attention** and **Try
  Again**. A reply from iCloud Mail, sent from the app 2 minutes 2 seconds after the start,
  left the Undo Send Window and waited: the Outbox read **1 waiting**, and its row
  **Waiting to send. It sends when this device can reach the mail server and your
  Unwired Mail account.** The outage lasted 2 minutes 49 seconds. Without a relaunch, the
  app connected to iCloud Mail 6 seconds after the outage ended, the list read **Syncing**
  with **Updating 2 accounts** 10 seconds after, and listed the message that had arrived
  during the outage 13 seconds after. The waiting reply was filed in iCloud Mail's Sent
  folder 28 seconds after the outage ended and arrived on `imap.seznam.cz` 3 seconds
  later, exactly one copy in each, with the same Message-ID. The app then held no
  lasting iCloud Mail connection until one opened 5 minutes 17 seconds after the outage
  ended and stayed open, consistent with an IDLE wait resuming after a retry pause grown
  to five minutes. Meanwhile a message arriving 1 minute 57 seconds after the end was
  listed 59 seconds after it arrived, just after brief connections whose trigger was not
  determined. Once the lasting connection had opened, a message appeared 5
  seconds after it arrived. **Connection recovery:** a second outage was started with
  the app waiting on iCloud Mail's Inbox, and 10 seconds later the app was terminated and
  launched again. It opened All Inboxes with iCloud Mail's saved messages and asked for
  no password. The header read **All Inboxes · Offline** with **1 account needs
  attention** and **Try Again**, and Email Accounts showed iCloud Mail as **Saved mail
  only until the mail server can be checked** and Seznam Email as **Updated just now**. A
  message submitted during this outage arrived on the server 61 seconds after its start.
  The outage lasted 2 minutes 57 seconds. Without a relaunch or any interaction, the app
  began connecting to iCloud Mail 2 minutes 26 seconds after the outage ended and was
  connected 2 seconds later, when the list read **Syncing**; it listed that message 6
  seconds after the first attempt. The attention notice was gone,
  and Email Accounts showed both mailboxes **Updated just now**. A message submitted
  next appeared 4 seconds after it arrived. Afterwards no run message remained in any
  folder of either mailbox, **Sign Out of This Device** returned the app to Welcome, and
  the Simulator was deleted. The scan of step 5 then covered `~/.agent-device`, `~/Library/Logs`,
  Xcode's DerivedData, the shell history, the temporary directories, the repository's
  `artifacts`, the operator's scratch files, this run's session transcript and T3
  Code's state database and logs; the Simulator's own files were deleted with it and not
  scanned. No scanned file this run wrote held a password or the Recovery Key; the only matches were the earlier runs' copies in T3 Code's state
  database and three of its logs, the latest written about four hours before this run
  ([#2688](https://github.com/unwired-dev/product/issues/2688)). Limitations: a first attempt loaded the
  rule without clearing the packet filter's states, and the open IDLE connection was
  still sampled established 71 seconds after the rule was loaded; it is not counted, but its reply, sent from the app during
  it, was sent once, 43 seconds after it ended. The app's closing of the
  open connection is read from the socket table, sampled every 2 seconds. The operator
  sent the first outage's reply from the reader and read the Outbox, which was still
  shown 6 seconds after that outage ended; All Inboxes was first sampled again 10 seconds
  after the end, and whether leaving the Outbox prompted the reconnection was not
  distinguished. The rule
  depended on the addresses those names resolved to on this Mac; every iCloud Mail
  address the app connected to on ports 993 and 587 during the run was in it. As in the
  2026-11-22 record, the outage cut the path on the Mac, so the Simulator saw no network
  change, and the screen readings were sampled every 1 to 3 seconds. Background refresh
  and push wakes, password recovery, Seznam Email outages and connection loss on iPad
  and Mac stay on #632.
- **2026-11-23, iPad lost connection to iCloud Mail
  ([#2707](https://github.com/unwired-dev/product/issues/2707)).** This run repeats the
  three cases of the iPhone rerun above on iPad. Target, toolchain and operator as in the
  first record, on a new iPad Pro 11-inch (M5) Simulator on iOS 27.0, with Simulator
  closed. Build: the app source of `6d21e32eb60d0083a071bbf4c89775bde84f9884`. Every
  credential was entered with pasteboard steps 1 to 3 above; Google Product Sign-In found
  the certification Product Account, **Unlock with Recovery Key** unlocked the device, and
  both mailboxes connected. Outage method: the iPhone rerun's packet-filter anchor, ports
  and state clearing, with the server names also looked up through the Mac's own
  resolver, which the Simulator uses and which can answer with addresses the direct
  queries do not return; 18 addresses were in the rule during both counted outages. The
  packet filter was off before the run and was turned off again after each outage. During
  both, `imap.mail.me.com` 993 and `smtp.mail.me.com` 587 timed out while
  `imap.seznam.cz` 993 and `smtp.seznam.cz` 465 connected, and every iCloud Mail address
  the app held open or tried on ports 993 and 587 was in the rule. Test messages were
  submitted and timed as in the iPhone rerun. Result: the three cases and the outage scope
  passed. Before any outage, a message appeared in the list 4 seconds after it arrived.
  **IDLE interruption and offline queueing:** the outage was started with All Inboxes open
  and the app's iCloud Mail connection waiting on the Inbox. The packet filter drops
  packets without answering, so that connection stayed in the socket table until after
  the outage; the app tried new iCloud Mail connections from 72 seconds after the start,
  and none completed. A message submitted 62 seconds after the start arrived on the server
  24 seconds later and was not listed while the outage lasted. The list header read **All
  Inboxes · Offline** with **1 account needs attention** and **Try Again**. A reply from
  iCloud Mail, sent from the app 1 minute 46 seconds after the start, waited: the Outbox
  read **1 waiting**, and its row **Waiting to send. It sends when this device can reach
  the mail server and your Unwired Mail account.** The app tried to reach the sending
  server about every 40 seconds. The outage lasted 3 minutes 19 seconds. Without a
  relaunch, the app reached the sending server 1 second after the outage ended; the reply
  was filed in iCloud Mail's Sent folder 5 seconds after the end and arrived on
  `imap.seznam.cz` 2 seconds later, exactly one copy in each, with the same Message-ID.
  The app replaced its stale Inbox connection 53 seconds after the end and listed the
  message that had arrived during the outage 5 seconds later, 58 seconds after the end. A
  message submitted next appeared 4 seconds after it arrived. **Connection recovery:** a
  second outage was started with the app waiting on iCloud Mail's Inbox, and 21 seconds
  later the app was terminated and launched again. It showed **Opening your mail…**, then
  All Inboxes with iCloud Mail's saved messages 26 seconds after the launch, and asked for
  no password. The header read **All Inboxes · Offline** with **1 account needs
  attention** and **Try Again**, and Email Accounts showed iCloud Mail as **Saved mail
  only until the mail server can be checked** and Seznam Email as **Updated just now**. A
  message submitted during this outage arrived on the server 70 seconds after its start.
  The outage lasted 4 minutes 8 seconds. Without a relaunch or any interaction, the app
  connected to iCloud Mail 79 seconds after the outage ended; the list read **Syncing**
  2 seconds later and listed that message 85 seconds after the end. The header then read **Updated
  just now** without the attention notice, Email Accounts showed both mailboxes **Updated
  just now**, and a message submitted next appeared 4 seconds after it arrived.
  Afterwards no run message remained in any folder of either mailbox, **Sign Out of This
  Device** returned the app to Welcome, and the Simulator was deleted. The scan of step 5
  then covered `~/.agent-device`, `~/Library/Logs`, Xcode's DerivedData, the shell
  history, the temporary directories, the repository's `artifacts`, the operator's
  scratch files, this run's session transcript and T3 Code's state database and logs;
  the Simulator's own files were deleted with it and not scanned. No scanned file this
  run wrote held a password or the Recovery Key; the only matches were the earlier runs'
  copies in T3 Code's state database and three of its logs, the latest written about 11
  hours before this run ([#2688](https://github.com/unwired-dev/product/issues/2688)).
  Limitations: a first attempt, whose rule held only the addresses the direct queries
  returned, missed the address of the app's open connection, left the probes connecting
  and was removed after 15 seconds; it is not counted, and the app was launched again
  before the first counted outage. The socket table was sampled every 2 seconds and the
  list several times a second. As in the iPhone rerun, the outage cut the path on the
  Mac, so the Simulator saw no network change. Background refresh and push wakes,
  password recovery, Seznam Email outages and connection loss on Mac stay on #632.

Real iCloud Mail and Seznam Email organizing, IDLE and Sent filing qualification, through
the app on both hosts, remains required before release
([#632](https://github.com/unwired-dev/product/issues/632)), as do native Mac
controlled-TLS reads and complete native IMAP setup/open/relaunch journeys on both
hosts. Registration Mock Mail Sessions connect any
IMAP login to a synthetic server that marks only its Sent folder, which the
[Mac](native-journeys.md#mac-imap-spam-and-trash-folder-journey) and
[iPhone and iPad](native-journeys.md#iphone-and-ipad-imap-spam-and-trash-folder-journey)
Spam and Trash folder journeys use; it is not provider qualification, and neither is the shared controlled-provider fixture.
