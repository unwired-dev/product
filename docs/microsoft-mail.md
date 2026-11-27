# Microsoft mail

[#634](https://github.com/unwired-dev/product/issues/634) connects a personal
Outlook.com or work/school Microsoft 365 mailbox as a **Mailbox Connection** and
reads its Inbox through Microsoft Graph on iPhone, iPad and Mac.
[#635](https://github.com/unwired-dev/product/issues/635) organizes and searches
its mail through Graph, and [#636](https://github.com/unwired-dev/product/issues/636)
sends from it through the [Outbox](outbox.md). It is mailbox
authorization only: Microsoft never becomes a Product Sign-In, and a Google or
Apple Product Account adds Microsoft mail without any Gmail grant. Microsoft
Product Sign-In and linking remain [#633](https://github.com/unwired-dev/product/issues/633).
Shared and delegated mailboxes are outside the [launch scope](product/power-user-launch.md).

## Connecting

After Google or Apple Product Sign-In and any [device admission](private-product-sync.md),
nothing asks a provider for mail. The account page shows **Connect your mail** with
the **Gmail** provider row, **Choose Another Google Mailbox** and, when Microsoft mail
is configured for this build, the **Microsoft 365 and Outlook** row.
A Google sign-in only suggests its own account to Gmail; it is never a Microsoft hint.

**Microsoft 365 and Outlook** opens Microsoft's sign-in page in the system web
authentication session and asks for `offline_access User.Read Mail.ReadWrite Mail.Send`,
so it can read, organize and send mail. The connection is shown only after Graph reads the
account and its Inbox:

| Outcome                                                           | What the person sees                                        |
| ----------------------------------------------------------------- | ----------------------------------------------------------- |
| Cancelled sign-in                                                 | **Mailbox access was cancelled**; the Product Account stays |
| Consent refused, or a grant without mail access                   | **Mail access was not granted**                             |
| Tenant restriction, admin consent required, or no Outlook mailbox | **Microsoft mail is unavailable for this account**          |
| Network or Microsoft service failure                              | **Mailbox access was interrupted**; retry resumes           |

Each outcome keeps the Product Account and offers retry or another provider,
including after relaunch. Once connected, Settings' **Email Accounts**
lists Gmail and Microsoft connections together and offers **Add a Microsoft Mailbox**.
That action also requires Microsoft mail to be configured for this build.
A connection whose grant Microsoft refuses later shows **Microsoft needs your
permission again** and **Allow Microsoft Access for** its address. Authorizing it
again suggests that account and must name the same Microsoft account; another
account is added separately.

A connection authorized before organizing was available keeps its read-only grant
and keeps synchronizing. Its first change that Microsoft refuses for lack of
permission stays saved on this device, and the Inbox shows **Microsoft needs your
permission again**. Allowing access again asks for organizing, and the saved
change is sent. A connection authorized before sending was available likewise keeps
reading and organizing with its grant. Its first message that Microsoft refuses for
lack of permission is **Not sent**, and the Inbox shows **Microsoft needs your
permission again**; allowing access again asks for sending, and **Edit** returns the
message to the Drafts to send again. Removal works as for [Gmail mailboxes](gmail-inbox.md#gmail-mailboxes)
and leaves the mail in Microsoft.

## Reading the Inbox

The Microsoft Inbox joins the unified Inbox with the same encrypted mailbox cache,
body cache, remote-content and attachment rules as Gmail. Synchronization follows initial listing and delta continuation pages. The initial
cache retains the newest 200 Inbox messages; each later synchronization updates
new or changed messages, read state and messages that left the Inbox, and saves
the newest delta link Graph returns even when nothing changed. Graph reads a
message a delta round names by its ID wherever it is now, so the folder it names
decides whether it left the Inbox or the folder being read. An
interrupted delta round resumes after relaunch. Losing a message from a full cache
admits the next older one. Expired delta state restarts synchronization while
saved mail stays visible; repeated expiry offers retry. A long or repeated delta
continuation pauses with its saved progress available for the next retry. Older
mail downloads separately through the
[Historical Metadata Backfill](#historical-metadata-backfill).

Opening a message reads its decoded HTML or text body, reply headers and paginated
attachment metadata. Only visible, sanitized Content-ID references fetch inline
image bytes through the usual per-image, aggregate transfer and shared display
budgets; hidden or unreferenced images do not download. Missing images or a failed
attachment-metadata read leave body text readable. Incomplete metadata is retried
on a later open, including after relaunch; a refused grant also asks for permission
again. Other attachments download only when asked. Graph's listed size is
approximate, so the downloaded file keeps its decoded byte size. Only file
attachments are listed; attached Outlook items and cloud links are not.

A meeting request or cancellation is an event message, so opening one also reads
the message's MIME (`/me/messages/{id}/$value`) for its calendar part, which the
[invitation card](invitation-responses.md#microsoft) answers. Only a meeting
message whose attachments total at most 4 MiB is read this way.

The constructed message's MIME metadata uses the same [budgets as Gmail](gmail-inbox.md#reading-messages).
An explicit open over a budget reports the body as failed, including when an
attachment's MIME type or Content-ID exceeds its limit. Metadata is never truncated.
If Graph also refuses the grant, the Inbox asks for authorization again instead.

## Browsing folders

Under its Inbox, each Microsoft mailbox's sidebar section lists **Sent Items**,
**Archive**, **Junk Email** and **Deleted Items**, then the mailbox's own folders by
path, such as **Projects / Launch**
([#1005](https://github.com/unwired-dev/product/issues/1005)). Archive, Junk Email
and Deleted Items appear once their folder roles are known and present, like the
actions that move mail there. Choosing a folder lists its newest messages, using the
same per-window choice, list heading, unread counts and bound as
[Gmail's label views](gmail-inbox.md#gmail-mailboxes): the newest 200 messages per
folder, the eight most recently opened folders, and every folder a window shows. These
folders also feed the [unified mailboxes](gmail-inbox.md#gmail-mailboxes) under
Favorites, where All Mail adds Drafts and Outbox; a mailbox without a known Archive,
Junk Email or Deleted Items folder shows as not included there.

Each folder keeps its own Graph delta link beside the Inbox's, so each
synchronization reads only that folder's changes, and the saved folders, their links
and waiting changes survive relaunch. A folder that loses a message from a full list
admits the next older one; an expired link lists the folder again while its saved
mail stays visible. Every folder says that only its newest mail is saved and older
mail stays in Microsoft. A folder Microsoft could not read keeps its saved messages
and shows **… could not be read from Microsoft** in the list and on its sidebar row
until a later synchronization reads it, while the Inbox stays current. A folder
removed in Outlook leaves the sidebar with its saved messages, and a window that
showed it returns to the Inbox. Restoring a window's chosen folder after relaunch
remains with [#1010](https://github.com/unwired-dev/product/issues/1010).

## Historical Metadata Backfill

Once a synchronization has made the Inbox current, the device downloads the
metadata of every message in the Inbox, Sent Items, Archive and the mailbox's own
folders in the background, a folder at a time, newest first, 50 messages per page
([#1519](https://github.com/unwired-dev/product/issues/1519), part of
[#1009](https://github.com/unwired-dev/product/issues/1009)). Junk Email, Deleted
Items, Drafts and Outbox stay out, as Gmail's Spam and Trash do. It shares
[Gmail's](gmail-inbox.md#historical-metadata-backfill) background lane, so it yields
to body loads and to every synchronization and never blocks using the Inbox. Each
saved page survives relaunch and interrupted requests. Resuming continues from
the last saved page; messages sharing a receipt time remain unique across pages,
including when mail moves or is deleted during the download. Downloaded metadata
uses encrypted device-local storage independently of opened-folder caches, whose
bounds never evict downloaded history.

When Move to lists only part of the mailbox's folders, each backfill run first
walks every folder list page, nested folders included, saving its place after
each page. Until that walk completes, including on later runs, the progress
names no total and is not complete, and no folder leaves the history. Each walk
step adds the folders found so far to the download as pending, so the progress
never shows complete before they are downloaded.

Changes made while the download runs are retained. Each synchronization keeps
new, moved, deleted and read mail current in the downloaded history: a message
moved to another folder leaves the first folder's history and joins the second's.
When Graph expires a folder's delta state, that folder downloads again while its
earlier history stays counted, and replaces it once the new pass completes. A
folder removed in Outlook leaves the history.

The Inbox state reports the progress per mailbox, like Gmail's: downloaded messages,
the total from each folder's item count, and whether every folder's download
and final reconciliation are complete.
Newly discovered folders remain pending, including when reading their item counts
fails; progress names no total until every folder's count is known.
The [Sync Status Capsule](gmail-inbox.md#sync-status-capsule) includes the pass, with
each connection's history status on Mac and in the capsule's details on iPhone and
iPad. A failed read, including Graph throttling, pauses the pass until the next
synchronization, and the state marks it paused. A refused grant asks for
authorization again; the pass keeps its place. Downloaded history is not shown in
folder lists or searched yet, so every folder still says that older mail stays in
Microsoft.

The [organizing actions](#organizing-and-searching) apply in every folder: Delete,
Move to Spam and Move to take a message out of the folder it is listed in, and
Archive stays an Inbox action. In Deleted Items and Junk Email, **Move to Inbox**
replaces Delete and Move to Spam, and restores the message to the Inbox; the iPhone
and iPad reader names it **Not Spam** in Junk Email.

## Organizing and searching

Microsoft mail offers the organizing actions Outlook has, in the reader and as
Inbox row actions: **Mark as Read** or **Mark as Unread**, **Archive**, **Delete**
(to Deleted Items), **Move to Spam** (to Junk Email), and **Move to** one of the
mailbox's own folders under **Folders**, nested ones included. Each folder shows its
path, such as **Inbox / Projects**, so folders with equal names stay apart. A mailbox
lists up to 250 folders, stopping at each folder's first provider page, and says
when some folders were left out. **Undo** moves a message back to
the Inbox. Opening an unread message sets its `isRead`, as
[Organizing mail](gmail-inbox.md#organizing-mail) describes for every provider. A Microsoft message lives in one folder, so Gmail's labels and star are
not offered for it. The row and reader [context menus](gmail-inbox.md#organizing-mail)
offer their supported actions in the documented order; Archive is row-only and Move to Spam remains outside those menus. Archive, Trash and Spam actions are offered only after their
folder roles are known and present in the mailbox.

Each change shows at once, is saved on this device and is sent to Microsoft in
order, exactly as for [Gmail](gmail-inbox.md):

- a change waits until the current Trusted Device can be verified, even when
  saved mail remains readable;
- a change Microsoft could not receive, or that it throttles or answers with a
  server error, waits and is sent again, including after relaunch;
- a change whose reply was lost is checked against where Microsoft has the message
  before it is sent again, so it is applied once;
- a message deleted in Outlook, or a folder removed there, refuses the change, and
  the Inbox shows the message as Microsoft has it;
- each change goes only to the connection that showed the message.

Mail-core also keeps each Microsoft message's Outlook categories, which Outlook
stores on the message apart from its folder
([#3019](https://github.com/unwired-dev/product/issues/3019), part of
[#1684](https://github.com/unwired-dev/product/issues/1684)). Listing, delta rounds,
search and organizing read them back, and a category change uses the same queue
as the changes above. Assigning or removing a category first reads the message's
categories as Microsoft has them now, then writes them back with only that
category added or removed. So a category another Outlook client changed before
that read stays as that client left it; a change made between the read and the
write can be overwritten. A change whose list Outlook could not store, such as
one with a name over 255 characters, is refused and the categories stay as
Microsoft has them. The write uses the existing `Mail.ReadWrite` grant.
The hosts don't offer categories yet: the approved Categories panel, the category
list in Settings and its `MailboxSettings` consent are later #1684 slices.

Online search covers every folder of each Microsoft mailbox beside Gmail's.
Microsoft orders its results by sent time and returns up to 1,000 matches; the
Inbox lists all returned results newest first.

## Sending

The composer offers Microsoft mailboxes as senders beside Gmail mailboxes and
[IMAP connections with SMTP](imap-mailboxes.md#sending). A Draft from a Microsoft
mailbox goes through the same [Outbox](outbox.md): the **Undo Send Window**, the
content-free claim through Convex and the recorded handoff come first, and only then
is the exact message, with its files and inline images, handed to Microsoft.
Only definite non-delivery is retried. Replies carry their `In-Reply-To` and `References`
headers, which Outlook threads by; Bcc recipients receive the message without
appearing in what others receive. The message is sent from the mailbox's own
address, and its Message-ID names that address's domain.

Microsoft accepting a message is not the same as its copy appearing in **Sent
Items**, which Microsoft files afterwards:

- a message Microsoft accepts leaves the Outbox at once;
- a message whose answer was lost, or that Microsoft answered with a server error,
  is **Delivery unknown** and is never sent again automatically. The app looks in
  Sent Items for exactly one copy with the message's own Message-ID when the outcome
  becomes unknown, when the app starts or becomes active and on **Check Again**. A
  copy that is not there yet leaves it unknown; a later check confirms it;
- a message Microsoft could not receive waits and is sent again, and one it
  throttles waits with **Microsoft asked to wait before sending more**;
- a refused grant, a message Microsoft finds too large, or another refusal is
  **Not sent** with **Edit**. Neither the message's mailbox nor this device as its
  Delivery Owner changes.

Graph accepts a message in one request of at most 4 MB, so `sendMail` takes
messages of up to 3 MB, files included. A larger message, up to 150 MB, is sent as
an Outlook draft instead
([#917](https://github.com/unwired-dev/product/issues/917)):

- after the claim, and before the recorded handoff, this device saves the message
  without its files in the mailbox's **Drafts** folder, then attaches each file.
  A file under 3 MB is attached in one request; a larger one goes through an
  attachment upload session in ranges. Only Microsoft's pre-authorized upload URL
  receives those ranges; the Graph token never does. File bytes stay in native code.
- nothing is delivered while the draft is prepared, so a refusal or interruption
  leaves the message waiting or **Not sent** as before, and it is never
  **Delivery unknown**. A refused step attempts to delete the new draft. A draft left behind
  when the app stopped carries the message's Message-ID, and the next attempt
  deletes it before saving a new one.
- **Edit** remains available offline. Cleanup of a known-unsent Outlook draft
  remains pending on this device after Edit and relaunch, and retries once the
  same mailbox is authorized and reachable. Cleanup never sends the draft.
  Removing authorization prevents cleanup; purging the account's local data also
  removes its pending cleanup intent, so an Outlook draft can remain.
- each file range requires current Trusted Device verification. Unavailable
  verification stops the upload, and revocation clears local authorization.
- the handoff is then recorded and the draft is sent once. Its outcome follows the
  rules below: an unknown one is confirmed only from Sent Items by Message-ID, and
  its draft is left alone because Microsoft may be sending it.
- the mailbox's own size limit is Microsoft's to enforce: a message it refuses as
  too large is **Not sent**. Send refuses a message over 150 MB, or one whose text
  alone is over 3 MB, and keeps the Draft open.

Drafts saved from MIME, upload sessions and a refused large message passed against real Graph
on iPhone in the [2026-11-23 run](#protected-outlookcom-runs); on Mac and iPad they
remain a release check in [#637](https://github.com/unwired-dev/product/issues/637).

## Credentials

Microsoft tokens must stay device-local, outside Private Sync, JavaScript and logs.
Other Trusted Devices learn the connection's provider and removal through encrypted
Private Sync, but each device authorizes the mailbox itself. Requests must be
limited to the signed-in person's own mail over authenticated HTTPS; a Microsoft
credential must never reach Gmail or another host. The
[architecture companion](architecture/microsoft-mail.md) records adapter evaluation,
credential custody and synchronization mechanisms.

## Configure the hosts

Register a public-client application in Microsoft Entra ID that accepts personal
Microsoft accounts and work or school accounts. Add the iOS/macOS redirect URI
`msauth.dev.unwired.mail://auth`, which both hosts share through the
`dev.unwired.mail` bundle ID, and the delegated Microsoft Graph permissions
`User.Read`, `Mail.ReadWrite` and `Mail.Send`. Set the application ID when generating each host:

```sh
UNWIRED_MICROSOFT_CLIENT_ID='<application (client) ID>' \
  mise exec -- pnpm native:generate
```

The variable is optional: without it the hosts offer neither the **Microsoft 365
and Outlook** row nor **Add a Microsoft Mailbox**. Mock builds always offer Microsoft mail. TestFlight uploads
read it from the root `.env.local` or the `MICROSOFT_GRAPH_CLIENT_ID` repository secret.

## Deterministic evidence

Shared tests drive the Microsoft Inbox through a controlled Graph mailbox: the
first list and delta round, later changes after relaunch, partial and repeated delta identities, an expired delta link,
bounded delta continuation work with saved progress for retry,
refilling a full cache, an HTML body with an inline image, an attachment download
by its decoded size, hidden/unreferenced images, optional image and attachment-metadata failures with
retry after relaunch, a refused grant, and a unified Inbox that searches both
providers online and sends from both. Folder tests in
`packages/mail-core/test/microsoft-folders.test.ts` list Sent Items, Junk Email and
nested folders of the mailbox's own from their own delta links, keep them current
through Outlook changes and relaunch without listing them again, delete from a
folder and restore from Deleted Items and Junk Email, refill a full folder, keep a
folder whose read fails with its saved mail, drop a folder removed in Outlook and
leave out a well-known folder the mailbox lacks. Organizing tests check Graph's read-state
and move requests, nested folder listing by path and its limit, Undo, an outage across relaunch, a lost reply,
throttling and server errors, a concurrent Outlook move, incomplete placement
replies, a deleted message or folder, missing folder roles, a read-only grant,
actions Microsoft lacks, search across folders and pages, and that changes reach only
the connection that showed the message. Registration-flow tests connect Microsoft mail as a Google or Apple
account's first mailbox without asking Google for mail, and cover cancellation, refused
consent, a missing mail scope, an unavailable mailbox and reauthorization. Both
hosts' rendered tests connect Microsoft mail first and show its Inbox.

History tests in `packages/mail-core/test/microsoft-history.test.ts` download the
Inbox, Sent Items, Archive and a folder of the mailbox's own while leaving out Deleted
Items, list messages sharing one receipt across pages once each, also when messages
listed before go during the pass or newly arrived mail shares that receipt,
resume after an interrupted page and relaunch without listing a page twice, keep new, moved, deleted
and read mail current during and after the pass, list a folder again after an
expired delta link without lowering progress, stay incomplete when the last continued
page's check is refused, pause on throttling and keep their place
through a refused grant, remain incomplete when a new folder's first count request
is throttled and recover after relaunch, and download 5,000 messages in bounded pages. The macOS
`native/private-inbox/integration/history.zsh` runner repeats them with the signed
native store holding the mailbox document and its history segments.

Sending tests in `packages/mail-core/test/microsoft-send.test.ts` send a threaded
reply with an inline image, an attachment and Bcc once after the Undo Send Window and
parse it with an independent MIME parser. They keep a lost answer unknown through
relaunch until Sent Items holds its copy, never sending it twice. Incomplete pages
and multiple matching copies retain the unknown outcome. They also map refused
grants, refusals, size, throttling, unreachable Microsoft and server errors to the
Outbox's outcomes without changing the connection; a refused grant asks for
Microsoft again. Send refuses a message over Graph's limit that Gmail would accept.
A failed cleanup of a known-unsent Outlook draft is retried by the Outbox's own
wake after its retry delay, without another Send or activation.

The hosted native suite stores a Microsoft connection beside Gmail, publishes its
own Private Sync descriptor, exercises the real token exchange, refresh and Graph
verification adapter with controlled HTTP responses, refuses Graph URLs outside the person's own mail and
Gmail requests with a Microsoft credential, and marks only its descriptor removed.
It also checks the read-state and move requests native code writes, refuses
malformed changes, and keeps a read-only or organize-only grant on refresh. Its send
writes the whole message, base64 encoded, to `sendMail` only with a current device
proof, refuses non-ASCII text, malformed files and a message over Graph's limit before
any request, and reports an interrupted request as unknown.
The `registration-apple` native journey connects the synthetic Microsoft mailbox
first, then adds Gmail. On iPhone it also searches for a folder with no match in
the **Move to…** sheet, checks that the search field and explanation stay above
the software keyboard, dismisses the sheet and reads the message after relaunch.

These are deterministic and mocked evidence. Real Microsoft authorization and
Graph transport on packaged hosts remain release checks on a personal account
(work/school accounts and tenant restrictions are covered by the mocked evidence
only, per the [launch scope](product/power-user-launch.md)), as do
confirming that Microsoft keeps a sent message's Message-ID in Sent Items (otherwise an
unknown outcome safely stays unknown), Bcc and threading in Outlook, and native
iPhone, iPad and Mac send journeys, in
[#637](https://github.com/unwired-dev/product/issues/637) and the launch
qualification [#855](https://github.com/unwired-dev/product/issues/855).

## Protected Outlook.com runs

Each record holds only non-secret facts: no addresses, tokens, authorization URLs or
mail content.

- **2026-11-18, iPhone connect and read
  ([#2386](https://github.com/unwired-dev/product/issues/2386)).** Target: Expo
  client, Release build without a Mock Mail Session, iPhone Simulator on iOS 27.0, with
  the development Convex deployment and the Microsoft public-client ID. Build: the app source of
  `d9d685353b829a161babd7018ac216f8aea17dc6`, which adds the callback fix from
  [#2389](https://github.com/unwired-dev/product/issues/2389).
  Toolchain: Xcode 27.2 (27B52). Operator: agent, with credentials read at run time from
  the approved password manager. Granted scopes, as the account's app permissions list
  them: `offline_access`, `User.Read`, `Mail.ReadWrite` and `Mail.Send`, the full
  requested set; Microsoft shows the app as unverified. Result: pass. Google Product Sign-In, then **Microsoft 365 and
  Outlook** connected the personal mailbox; the Inbox listed real messages and one opened
  in the reader. Before the fix, every real consent ended on **Mailbox access was
  interrupted**. Limitations: after connecting, Private Sync pulls failed as unavailable
  ([#2390](https://github.com/unwired-dev/product/issues/2390)). Mac, iPad, organizing,
  search, attachments, sending, renewal after relaunch and revocation were not run and
  stay on #637.
- **2026-11-22, iPhone connect after the app becomes active again
  ([#2676](https://github.com/unwired-dev/product/issues/2676)).** Target, operator and
  toolchain as on 2026-11-18. Build: the app source of
  `8c26803c132385f75843d98309055779dd4f7a04`, then the same source with the fix from
  #2676. Result: fail, then pass with the fix. Google Product Sign-In and the Recovery
  Key, then **Microsoft 365 and Outlook**, connected the personal mailbox, but its Inbox
  stayed on **Loading Inbox** until the app was relaunched; removing the mailbox and
  connecting it again showed the same each time the connection's first synchronization
  overlapped the restore that the return from Microsoft's sign-in sheet started. With
  the fix, two such overlapping connects each listed the real Inbox without a relaunch,
  and two connects that did not overlap listed it as before. One message then opened in
  the reader with its body, in Light and Dark. Limitations: Mac, iPad and the other
  areas the 2026-11-18 run left out were not run.
- **2026-11-23, iPhone organize and search
  ([#2693](https://github.com/unwired-dev/product/issues/2693)).** Target: Expo client,
  Release build without a Mock Mail Session, iPhone 18 Pro Simulator on iOS 27.0, with
  the development Convex deployment and the Microsoft public-client ID. Build: the app
  source of `1ac442d43fae08e8ef53bb50e24bc2597f30070d`, then the same source with the fix
  from #2693 (`411d396fb1ed0a07062dcc2dbd5a2680f58322bf`) installed over it. Toolchain:
  Xcode 27.2 (27B52). Operator: agent, with credentials read at run time from the
  approved password manager. Result: fail, then pass with the fix. The Google password,
  the Recovery Key and the Microsoft address and password went in through the Simulator
  pasteboard as [IMAP mailboxes](imap-mailboxes.md) describes; Google Product Sign-In,
  **Unlock with Recovery Key** and **Microsoft 365 and Outlook** connected the personal
  mailbox and its Inbox listed real messages. **Mark as Unread** and **Mark as Read**
  showed at once and survived a relaunch. Before the fix, **Move to** and **Archive**
  reached Graph, and the destination folder listed the message, but its Inbox row stayed
  after synchronization, a relaunch and a refresh: Graph answers a read of a message
  through a folder it has left, so the delta round kept it. With the fix, a message moved
  to **Conversation History**, deleted there and moved back with **Move to Inbox** from
  **Deleted Items**, moved again and returned with **Undo**, and then archived each time
  left the list it was moved from and appeared in the other, also after a relaunch.
  Search for a word from a subject found real messages on this device and on the mail
  server, and a search with no match showed **No Results** in both. After **Sign Out of
  This Device** and deleting the Simulator, the credential scan covered
  `~/.agent-device`, `~/Library/Logs`, Xcode's DerivedData, the repository's
  `artifacts`, the shell history, the temporary directories, this run's session
  transcripts and T3 Code's state. This run's own files, provider log and transcripts
  held no password or Recovery Key. The scan found the Recovery Key in T3 Code's state
  database, which every session writes, and in three agent provider logs last written
  the day before by earlier runs
  ([#2688](https://github.com/unwired-dev/product/issues/2688)). Limitations:
  Microsoft's one-time sign-in code was typed, as it expires within minutes; rows the
  earlier build kept stayed in the saved Inbox until those messages returned to it.
  Mac, iPad and the other areas the 2026-11-18 run left out were not run.
- **2026-11-23, iPhone send and reply
  ([#2697](https://github.com/unwired-dev/product/issues/2697)).** Target, operator and
  toolchain as on 2026-11-18, on an iPhone 18 Pro Simulator. Build: the app source of
  `1ac442d43fae08e8ef53bb50e24bc2597f30070d`. Result: pass. A fresh Google Product
  Sign-In with the Recovery Key, then **Microsoft 365 and Outlook**, connected the
  personal mailbox with every credential entered through the
  [Simulator pasteboard](imap-mailboxes.md#certification-runs-through-the-app), none
  typed. A new message to the mailbox's own address left the Outbox after the
  **Undo Send Window**, appeared in **Sent Items** and arrived in the Inbox. A reply to
  it arrived with the original's subject, Sent Items listed it, and Outlook on the web
  grouped it with the original. All of them remained after a relaunch. **Undo** during
  the window returned the message to the composer as a Draft with its recipient, and it
  never reached Sent Items or the Inbox. After the Simulator was deleted, the credential
  scan found nothing. Limitations: the first Undo
  attempt was pressed after the 10-second window had closed, because the automation
  waited for the button to settle, so that message was sent; a second attempt about
  3 seconds after Send was undone. The iPhone reader shows the reply on its own, as it
  does any message, rather than with its Thread
  ([#846](https://github.com/unwired-dev/product/issues/846)). Mac, iPad, attachments,
  uncertain outcomes, renewal after relaunch and revocation were not run and stay on
  #637.
- **2026-11-23, iPhone attachments
  ([#2709](https://github.com/unwired-dev/product/issues/2709)).** Target, operator and
  toolchain as on 2026-11-18, on an iPhone 18 Pro Simulator. Build: the app source of
  `c95a25bbc92a4dbee831f21b423038926489d0d9`, then the same source with the fix from
  #2709 installed over it. Result: fail, then pass with the fix. A fresh Google Product
  Sign-In with the Recovery Key, then **Microsoft 365 and Outlook**, connected the
  personal mailbox with the passwords and the Recovery Key entered through the
  [Simulator pasteboard](imap-mailboxes.md#certification-runs-through-the-app). A new
  message to the mailbox's own address with a PDF from **Attach File** and a photo from
  **Attach Photo** left the Outbox after the **Undo Send Window**, appeared in **Sent
  Items** and arrived in the Inbox. Before the fix, the reader showed its text with a
  placeholder for the photo, **Images in this message are not loaded.** and no
  attachment list: Graph refused the attachment list with status 400, because it
  selected the Content-ID without naming the file attachment type. With the fix, the
  photo showed in the body and the PDF was listed below it with Graph's listed size;
  **Download** saved it with its name and exactly the bytes sent, and **Open** showed it
  in Quick Look. After a relaunch the photo still showed and the PDF was listed with
  **Download**, because a relaunch deletes the files an earlier process downloaded, and
  it downloaded again. After **Sign Out of This Device**, the credential scan covered the
  places the 2026-11-23 organize run lists and the Simulator. This run's own files,
  provider log and transcripts held no password or Recovery Key. The Simulator's system
  log held the Recovery Key: XCTest's test manager wrote it when an accessibility
  snapshot read the **Recovery Key** field after the paste, which the
  [pasteboard procedure](imap-mailboxes.md#certification-runs-through-the-app) forbids.
  Deleting the Simulator removed it. T3 Code's state database and the three provider
  logs of 2026-11-22 still held it, as tracked in #2688. Limitations: Microsoft's
  one-time sign-in code was typed, as it expires within minutes. Mac, iPad, attachments of 3 MB or more, uncertain outcomes, renewal after
  relaunch and revocation were not run and stay on #637.
- **2026-11-23, iPhone attachments of 3 MB or more
  ([#2719](https://github.com/unwired-dev/product/issues/2719)).** Target, operator and
  toolchain as on 2026-11-18, on an iPhone 18 Pro Simulator. Build: the app source of
  `f257226c0c8786b58784c9a4f497ee2ec8ed5a38`. Result: pass for the checks run, with three
  checks not run (below). A fresh Google Product
  Sign-In with the Recovery Key, then **Microsoft 365 and Outlook**, connected the
  personal mailbox with the passwords and the Recovery Key entered through the
  [Simulator pasteboard](imap-mailboxes.md#certification-runs-through-the-app). A new
  message to the mailbox's own address with one 10,000,000-byte file left the Outbox
  after the **Undo Send Window**: its file went up through an upload session in three
  ranges, the last answered 201. The message appeared once in **Sent Items** and arrived
  once in the Inbox; **Download** saved exactly the bytes sent, and after a relaunch the file was
  still listed with **Download**. A second message with two 24,000,000-byte files, each
  under the 25 MiB file limit and together under Send's 150 MB limit, uploaded the first
  file completely; Microsoft answered the last range of the second with status 400. The
  app deleted the Outlook draft, and the Outbox showed **Not sent. Microsoft refused this
  message.** with **Edit**, also after a relaunch. Nothing reached Sent Items or the Inbox. After the
  Simulator was deleted, the credential scan of this run's own files, `~/.agent-device`
  and the Simulator's logs found nothing; before deletion, the Simulator's system log
  and one of its system Siri model files matched a credential value. Limitations: Microsoft's one-time sign-in code was typed, as
  it expires within minutes. The body of the 400 answer was not recorded, so the run
  shows that Microsoft refused the message, not why. Not run: looking in **Drafts** for
  an Outlook draft after the successful send, checking the downloaded file's name, and
  pressing **Edit** on the refused message; they stay on #2719. Mac, iPad,
  uncertain outcomes, renewal after relaunch and revocation were not run and stay on
  #637.
- **2026-11-23, iPhone attachments of 3 MB or more, rerun
  ([#2719](https://github.com/unwired-dev/product/issues/2719)).** Target, operator and
  toolchain as on 2026-11-18, on a new iPhone 18 Pro Simulator. Build: the Release build of
  the run above, from the app source of `f257226c0c8786b58784c9a4f497ee2ec8ed5a38`; only
  documentation changed before this run. Result: two of the three checks the run above left
  out pass; the third could not run because Microsoft locked the account
  ([#2724](https://github.com/unwired-dev/product/issues/2724)). A fresh Google Product
  Sign-In with the Recovery Key, then **Microsoft 365 and Outlook**, connected the personal
  mailbox with the passwords and the Recovery Key entered through the
  [Simulator pasteboard](imap-mailboxes.md#certification-runs-through-the-app). In the
  reader, the 10,000,000-byte message of the run above listed its file, and **Download**
  saved it under its own name with 10,000,000 bytes. A new message with two
  24,000,000-byte files uploaded the first file completely; Microsoft answered the last
  range of the second with status 400, as before. The app deleted the Outlook draft, the
  Outbox showed **Not sent. Microsoft refused this message.**, and **Edit** returned it to
  the composer with its recipient, subject, text and both files. Not run: looking in
  **Drafts** after a successful send. A new message with one 10,000,000-byte file went up
  through an upload session in three ranges, the last answered 201, but Microsoft answered
  the draft's send with status 403, and a text-only message's send with 403 too, while
  reads still succeeded. Both ended **Not sent. This mailbox needs Microsoft access
  again.**, and the app deleted the 10 MB message's Outlook draft. **Allow Microsoft
  Access** then opened Microsoft's notice that it had locked the account for activity
  against the Microsoft Services Agreement and asked the person to show they are human; the
  agent stopped there. After the Simulator was deleted, the credential scan of this run's
  own files, `~/.agent-device`, the Simulator's logs, the shell history, the temporary
  directory, this run's session transcripts, `~/Library/Logs`, Xcode's DerivedData and the
  repository's `artifacts` directory found nothing; before deletion, the
  Simulator's system log and two of its system search files matched a credential value.
  Limitations: Microsoft's one-time sign-in code was typed, as it expires within minutes.
  Typing the recipient opened the system's contacts access sheet, and the Simulator's sample
  contacts were shared. The bodies of the 400 and 403 answers were not recorded. Mac, iPad,
  uncertain outcomes, renewal after relaunch and revocation were not run and stay on #637.
- **2026-11-24, iPhone attachments of 3 MB or more, Drafts after a successful send
  ([#2719](https://github.com/unwired-dev/product/issues/2719)).** Target, operator and
  toolchain as on 2026-11-18, on a new iPhone 18 Pro Simulator, after the owner had the
  account of #2724 unlocked. Build: a new Release build from the app source of
  `7372eadb538a227f4eb8549477308498ef0fce25`. Result: pass. A fresh Google Product Sign-In
  with the Recovery Key, then **Microsoft 365 and Outlook**, connected the personal
  mailbox with the passwords and the Recovery Key entered through the [Simulator
  pasteboard](imap-mailboxes.md#certification-runs-through-the-app). A new message to the
  mailbox's own address with one 10,000,000-byte file from **Attach File** left the Outbox
  once the **Undo Send Window** had passed: 12 seconds after **Send**, its file went up
  through an upload session in three ranges, the last answered 201, and the send was
  answered 202. The message appeared once in **Sent Items** and arrived once in the Inbox,
  and **Drafts** in Outlook on the web then showed **Nothing in Drafts**. With the two
  runs above, every check of #2719 has now passed. After **Sign Out of This Device** and
  deleting the Simulator, the credential scan of this run's scratch directory,
  `~/.agent-device`, `~/Library/Logs`, the repository's `artifacts/expo-bootstrap`
  directory with this run's DerivedData, the shell history and this run's session
  transcripts found nothing. Limitations: Microsoft's one-time sign-in code was typed, as
  it expires within minutes. Mac, iPad, uncertain outcomes, renewal after relaunch and
  revocation were not run and stay on #637.
- **2026-11-24, iPhone renewal after relaunch and revocation
  ([#2847](https://github.com/unwired-dev/product/issues/2847)).** Target, operator and
  toolchain as on 2026-11-18, on a new iPhone 18 Pro Simulator. Build: a new Release build
  from the app source of `8d5bdaa015222a84e2f7a5767fc861d63df13072`. Result: pass for
  sending after relaunch and for recovery, with a defect in the refused state
  ([#2853](https://github.com/unwired-dev/product/issues/2853)). A fresh Google Product
  Sign-In with the Recovery Key, then **Microsoft 365 and Outlook**, connected the
  personal mailbox with the passwords and the Recovery Key entered through the [Simulator
  pasteboard](imap-mailboxes.md#certification-runs-through-the-app); Microsoft reused the
  account's earlier grant without asking for consent, and the app was closed. A relaunch
  66 minutes after connecting synchronized the Inbox with no Microsoft sign-in, and a new
  message to the mailbox's own address left the Outbox, appeared in **Sent Items** and
  arrived in the Inbox within 3 minutes. The app's permissions were then removed from the
  Microsoft account's **Apps and services you've given access**. A relaunch right
  afterwards still synchronized. A relaunch 54 minutes later
  opened the account page with **Connect your mail** instead of the Inbox, listing the
  mailbox with **Microsoft needs your permission again**, **Allow Microsoft Access for**
  its address and **Remove**; it said **Microsoft
  mail is unavailable for this account. Its organization may need to approve Unwired
  Mail…**, and the saved mail was closed, as [Gmail
  mailboxes](gmail-inbox.md#gmail-mailboxes) describes for every mailbox needing
  authorization again. Nothing was sent. **Allow Microsoft Access for** the address showed
  Microsoft's consent with no password prompt, and the Inbox returned with the mailbox
  kept; Microsoft's account page then listed the full requested set of scopes again. A new
  message left the Outbox, appeared in **Sent Items** and arrived in the Inbox within
  4 minutes. Removing the permissions a second time, then relaunching 55 minutes later,
  opened the same account page. After **Sign Out of This Device** and deleting the
  Simulator, the credential scan of `~/.agent-device`, `~/Library/Logs`, the shell history,
  the repository's `artifacts` directory with this run's DerivedData, this run's scratch and
  temporary directories and its session transcripts found no password or Recovery Key.
  Limitations: the run did not record when Microsoft's access tokens expired or when the
  app asked for a new one, so renewal after expiry remains unverified. Microsoft's one-time sign-in codes were typed, as they expire within minutes.
  Mac, iPad and uncertain outcomes were not run and stay on #637.
- **2026-11-25, iPad connect, read, send and reply
  ([#2877](https://github.com/unwired-dev/product/issues/2877)).** Target: Expo client,
  Release build without a Mock Mail Session, new iPad Pro 11-inch (M5) Simulator on
  iOS 27.0, with the development Convex deployment and the Microsoft public-client ID.
  Build: the app source of `d72ed590e934fd8cf1dfd2078d586511b7bed637`. Toolchain: Xcode
  27.2 (27B52). Operator: agent, with credentials read at run time from the approved
  password manager. Result: partial. Connect, read, send and reply passed; the Undo Send
  window remains unverified, and the credential criterion failed, as a screenshot showed
  the Recovery Key (below). A fresh Google Product Sign-In with the Recovery Key, then
  **Microsoft 365 and Outlook**, connected the personal mailbox with every address, password and the Recovery Key entered through the
  [Simulator pasteboard](imap-mailboxes.md#certification-runs-through-the-app). Microsoft
  asked for the requested scopes again, as the 2026-11-24 run had removed the app's
  permissions, and the Inbox opened in the iPad's split layout after **Accept**, listing
  real messages; one opened in the reader beside the list with its body. A new message to
  the mailbox's own address appeared once in **Sent Items** 27 seconds after **Send** and
  arrived in the Inbox. A reply to it showed an **Outbox** row in the sidebar 7 seconds
  after **Send**, which had left it 16 seconds after; the reply appeared once in Sent
  Items and arrived in the Inbox with the original's subject. **Sign Out of This Device**
  returned the app to Welcome. Credential exposure: on the first attempt to paste the
  Recovery Key, iPadOS's **Copy and Paste** tip covered the keyboard and took the press, so
  nothing was pasted; once it was dismissed, a screenshot taken to find the field showed
  the Recovery Key in plain text in the software keyboard's **Paste from
  CoreSimulatorBridge** suggestion, although the pasteboard had been cleared. The file
  was deleted at once, but the image remains in that session's transcript on the Mac, where
  a text scan cannot find it ([#2688](https://github.com/unwired-dev/product/issues/2688)).
  The Recovery Key was then pasted with the field scrolled above the keyboard and nothing
  read the screen until the field was gone. With both Simulators deleted,
  `simulator-credentials.zsh scan`, run on each path, found no password or Recovery Key in
  `~/.agent-device`, `~/Library/Logs`, `artifacts`, Xcode's DerivedData, the shell history,
  the temporary directory, the scratch files or the session transcripts; one scan of all
  paths at once ended with a read error and was repeated per path. Limitations:
  Microsoft's one-time sign-in code was typed, as it expires within minutes. The Undo Send
  window of the first message was not observed, and **Undo** was not pressed. A second
  attempt on a new iPad Simulator, to watch that window, stopped at Microsoft's code step:
  codes typed quickly lost digits, three codes entered in full were refused, and the
  agent-device runner then hung, so the Simulator was deleted without **Sign Out of This
  Device**. Typing the recipient opened the system's contacts access sheet, answered
  **Don’t Allow**. Mac, iPad organizing, search,
  attachments, renewal and revocation, and uncertain outcomes were not run and stay on
  #637.
- **2026-11-26, iPad Undo Send window and credential handling, rerun
  ([#2877](https://github.com/unwired-dev/product/issues/2877)).** Target, operator and
  toolchain as on 2026-11-25, on a new iPad Pro 11-inch (M5) Simulator on iOS 27.0, after
  the owner confirmed that protected sign-in was unblocked. Build: a new Release build
  from the app source of `4e72a1ac22706df0537a1f5312d38d74e8e0cb7a`. Result: pass. A
  fresh Google Product Sign-In with the Recovery Key, then **Microsoft 365 and Outlook**,
  connected the personal mailbox with every address, password and the Recovery Key
  entered through the [Simulator
  pasteboard](imap-mailboxes.md#certification-runs-through-the-app); Microsoft reused the
  account's earlier grant without asking for consent. The split layout showed the
  mailbox as **Syncing**, then the Inbox listed real messages, and one opened in the reader beside the list. With the
  sidebar shown, a new message to the mailbox's own address put an **Outbox** row after
  **Sent**; selecting it listed **1 waiting** and the message with **Sending soon** and
  **Undo**. **Undo**, pressed about 5 seconds after **Send**, returned the message to the
  composer as a Draft with its recipient, subject and text. Sent again, it still read
  **Sending soon** 11 seconds after **Send** and had left the Outbox at 13 seconds; it appeared
  once in **Sent Items** and arrived in the Inbox. A reply to it from the reader still read
  **Sending soon** in the Outbox 11 seconds after **Send**, had left it at 14 seconds,
  appeared once in Sent Items and arrived in the Inbox with the original's subject.
  **Sign Out of This Device** returned the app to Welcome. Nothing read the screen while
  the Recovery Key field held the key, and no screenshot was taken while the software
  keyboard was shown after a pasted credential. With the Simulator deleted,
  `simulator-credentials.zsh scan`, run on each path, found no password or Recovery Key in
  `~/.agent-device`, `~/Library/Logs`, T3 Code's device directory, the shell history, the
  temporary directory, the repository's `artifacts/expo-bootstrap` directory with this run's
  DerivedData, the scratch files or this run's session transcripts. Limitations:
  Microsoft's one-time sign-in code was typed, as it expires within minutes; the first
  attempt typed no digit and the same code entered more slowly was accepted. An earlier
  new message, sent while the sidebar was hidden, left the Outbox unobserved; it appeared
  once in Sent Items and arrived in the Inbox. Pasting the recipient opened the system's
  contacts access sheet, answered **Don’t Allow**. Mac, iPad organizing, search,
  attachments, renewal and revocation, and uncertain outcomes were not run and stay on
  #637.
- **2026-11-26, iPad organize and search
  ([#3017](https://github.com/unwired-dev/product/issues/3017)).** Target, operator and
  toolchain as on 2026-11-25, on a new iPad Pro 11-inch (M5) Simulator on iOS 27.0.
  Build: a new Release build from the app source of
  `209dfa939362fb67e8fef90f7f21a38af90302f4`. Result: partial: organize and search passed,
  and credential handling is unverified (see the limitations). A fresh Google Product
  Sign-In with the Recovery Key, then **Microsoft 365 and Outlook**, connected the
  personal mailbox with every address, password and the Recovery Key entered through the
  [Simulator pasteboard](imap-mailboxes.md#certification-runs-through-the-app); Microsoft
  reused the account's earlier grant without asking for consent. **Mark as Unread** and
  **Mark as Read** from the row's menu showed at once and survived a relaunch. In the
  reader with the sidebar hidden, **Folders** › **Conversation History** took a message
  out of the Inbox and **Conversation History** listed it. **Delete** there moved it to
  **Deleted Items**, whose row menu's **Move to Inbox** brought it back. Moved again, it
  returned with **Undo**, and the row menu's **Archive** then moved it to **Archive**.
  After each step and a relaunch, the message had left the list it was moved from and was
  listed in the other. A search for a word from the subjects listed 12 messages under
  **Top Results**, each saying **Saved on this device** or **Downloads from the mail
  server when opened**. **Search Mail Servers** then listed real messages under **From
  mail servers**, including **Sent Items** copies this device had never listed, with
  **More from Mail Servers**. A search with no match showed **No Results**, said that no
  saved mail in the mailbox matched, and after **Search Mail Servers** that the mail
  servers found none. **Sign Out of This Device** returned the app to Welcome. With the
  Simulator deleted, `simulator-credentials.zsh scan`, run on each path, found no password
  or Recovery Key in `~/.agent-device`, `~/Library/Logs`, T3 Code's device directory, the
  shell history, the temporary directory, the repository's `artifacts` directory with this
  run's DerivedData, the scratch files or this run's session transcripts; some files in
  the temporary directory could not be read. Limitations: Microsoft's one-time sign-in
  code was typed, as it expires within minutes. The first three codes entered were
  refused: the mailbox that receives them opened their conversation at its oldest unread
  message, so expired codes were read; the code read from the newest message was accepted.
  Once, after a switch to that mailbox, Microsoft's sheet restarted at its first page.
  When the accessibility snapshot could not read the sheet, the device driver saved a
  screenshot on its own three times, against the pasteboard procedure; two, which may have
  shown a pasted address, were deleted unopened, and the one opened showed Microsoft's
  first page with no keyboard. The scan reads text, not these images, so it cannot show
  that no password or Recovery Key was captured. Mac, iPad attachments, renewal and
  revocation, and uncertain outcomes were not run and stay on #637.
- **2026-11-27, iPhone meeting invitation response
  ([#2703](https://github.com/unwired-dev/product/issues/2703)).** Target, operator and
  toolchain as on 2026-11-18, on a new iPhone 18 Pro Simulator. Build: a new Release build
  from the app source of `7be517a81d85c21722ffc86d62a0c390587314ff`, then the same source
  with the fix from [#3024](https://github.com/unwired-dev/product/issues/3024)
  (`ff652f9ce6d288cd48bc1263e392fcbb02ba11f0`) installed over it. Result: fail, then pass
  with the fix. A fresh Google Product Sign-In with the Recovery Key, then **Microsoft 365
  and Outlook**, connected the personal mailbox with the passwords and the Recovery Key
  entered through the [Simulator
  pasteboard](imap-mailboxes.md#certification-runs-through-the-app). A separate iCloud
  test mailbox, the organizer, sent three meeting requests for the Outlook.com address,
  each with one `text/calendar; method=REQUEST` part. Outlook.com filed one in **Junk
  Email** and the others in the Inbox. Opening each showed the invitation card with the
  meeting's time, **Invited, You, {address} · Outlook.com** and **Accept**, **Maybe** and
  **Decline**. Before the fix, **Accept** read **Accepted. Outlook.com confirmed it sent
  your response…**, and the organizer's mailbox received the response with its text, but
  Exchange had replaced its `METHOD:REPLY` with an empty part, once from Junk Email and
  once from the Inbox. With the fix, **Maybe** on the third read **Tentatively accepted.
  Outlook.com confirmed it sent your response…**, and the organizer's mailbox received one
  `METHOD:REPLY` with the invitation's UID, the Outlook.com attendee with
  `PARTSTAT=TENTATIVE`, and the meeting's start, which Exchange rewrote in a named time
  zone. **Sign Out of This Device** returned the app to Welcome. With the Simulator
  deleted, `simulator-credentials.zsh scan`, run on each path, found no password or
  Recovery Key in `~/.agent-device`, `~/Library/Logs`, T3 Code's device directory, the
  shell history, the scratch files, the repository's `artifacts/expo-bootstrap` directory
  with this run's DerivedData or this run's session transcripts. The six-digit one-time
  code the scan also looked for matched once, inside an unchanged test vector of a Swift
  package checkout, and no longer matched once the code had changed. Limitations: Microsoft's one-time
  sign-in code was typed, as it expires within minutes. **Decline**, a cancelled,
  someone-else's or ambiguous invitation, a refused or unconfirmed response and **Check
  Again** were not run on the live mailbox; the synthetic Graph mailbox tests cover a
  lost response found again in Sent Items, and the other states share the Gmail tests.
  Mac and iPad were not run.
