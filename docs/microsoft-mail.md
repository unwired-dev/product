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
**Authorize Gmail**, **Choose another Google mailbox** and, when Microsoft mail is
configured for this build, **Connect Microsoft mail**.
A Google sign-in only suggests its own account to Gmail; it is never a Microsoft hint.

**Connect Microsoft mail** opens Microsoft's sign-in page in the system web
authentication session and asks for `offline_access User.Read Mail.ReadWrite Mail.Send`,
so it can read, organize and send mail. The connection is shown only after Graph reads the
account and its Inbox:

| Outcome                                                           | What the person sees                                               |
| ----------------------------------------------------------------- | ------------------------------------------------------------------ |
| Cancelled sign-in                                                 | **Mailbox authorization was cancelled**; the Product Account stays |
| Consent refused, or a grant without mail access                   | **Mail access was not granted**                                    |
| Tenant restriction, admin consent required, or no Outlook mailbox | **Microsoft mail is unavailable for this account**                 |
| Network or Microsoft service failure                              | **Mailbox authorization was interrupted**; retry resumes           |

Each outcome keeps the Product Account and offers retry or another provider,
including after relaunch. Once connected, the account page's **Mailboxes** section
lists Gmail and Microsoft connections together and offers **Add a Microsoft mailbox**.
That action also requires Microsoft mail to be configured for this build.
A connection whose grant Microsoft refuses later shows **Microsoft needs your
permission again** and **Allow Microsoft access for** its address. Authorizing it
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
the newest delta link Graph returns even when nothing changed. An
interrupted delta round resumes after relaunch. Losing a message from a full cache
admits the next older one. Expired delta state restarts synchronization while
saved mail stays visible; repeated expiry offers retry. A long or repeated delta
continuation pauses with its saved progress available for the next retry. This slice does not claim
complete historical metadata backfill.

Opening a message reads its decoded HTML or text body, reply headers and paginated
attachment metadata. Only visible, sanitized Content-ID references fetch inline
image bytes through the usual per-image, aggregate transfer and shared display
budgets; hidden or unreferenced images do not download. Missing images or a failed
attachment-metadata read leave body text readable. Incomplete metadata is retried
on a later open, including after relaunch; a refused grant also asks for permission
again. Other attachments download only when asked. Graph's listed size is
approximate, so the downloaded file keeps its decoded byte size. Only file
attachments are listed; attached Outlook items and cloud links are not.

The constructed message's MIME metadata uses the same [budgets as Gmail](gmail-inbox.md#reading-messages).
An explicit open over a budget reports the body as failed, including when an
attachment's MIME type or Content-ID exceeds its limit. Metadata is never truncated.
If Graph also refuses the grant, the Inbox asks for authorization again instead.

## Organizing and searching

Microsoft mail offers the organizing actions Outlook has, in the reader and as
Inbox row actions: **Mark as read** or **Mark as unread**, **Archive**, **Move to
Trash** (Deleted Items), **Report spam** (Junk Email), and **Move to** one of the
mailbox's own folders under **Folders**, nested ones included. Each folder shows its
path, such as **Inbox / Projects**, so folders with equal names stay apart. A mailbox
lists up to 250 folders, stopping at each folder's first provider page, and says
when some folders were left out. **Undo** moves a message back to
the Inbox. A Microsoft message lives in one folder, so Gmail's labels and star are
not offered for it. Archive, Trash and Spam actions are offered only after their
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

Online search covers every folder of each Microsoft mailbox beside Gmail's.
Microsoft orders its results by sent time and returns up to 1,000 matches; the
Inbox lists all returned results newest first.

## Sending

The composer offers Microsoft mailboxes as senders beside Gmail mailboxes and
[IMAP connections with SMTP](imap-mailboxes.md#sending). A Draft from a Microsoft
mailbox goes through the same [Outbox](outbox.md): the **Undo Send Window**, the
content-free claim through Convex and the recorded handoff come first, and only then
is the exact message, with its files and inline images, handed to Microsoft
through Graph's `sendMail`. Only definite non-delivery is retried. Replies carry their `In-Reply-To` and `References`
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

Graph accepts a message in one request of at most 4 MB, so a Microsoft mailbox sends
messages of up to 3 MB here, files included; Send refuses a larger one and keeps the
Draft open. Larger messages, which need Outlook drafts and attachment upload
sessions, are a later slice.

## Credentials

Microsoft tokens must stay device-local, outside Private Sync, JavaScript and logs.
Other Trusted Devices learn the connection's provider and removal through encrypted
Private Sync, but each device authorizes the mailbox itself. Requests must be
limited to the signed-in person's own mail over authenticated HTTPS; a Microsoft
credential must never reach Gmail or another host. The reviewer-only
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

The variable is optional: without it the hosts offer neither **Connect Microsoft
mail** nor **Add a Microsoft mailbox**. Mock builds always offer Microsoft mail. TestFlight uploads
read it from the root `.env.local` or the `MICROSOFT_GRAPH_CLIENT_ID` repository secret.

## Deterministic evidence

Shared tests drive the Microsoft Inbox through a controlled Graph mailbox: the
first list and delta round, later changes after relaunch, partial and repeated delta identities, an expired delta link,
bounded delta continuation work with saved progress for retry,
refilling a full cache, an HTML body with an inline image, an attachment download
by its decoded size, hidden/unreferenced images, optional image and attachment-metadata failures with
retry after relaunch, a refused grant, and a unified Inbox that searches both
providers online and sends from both. Organizing tests check Graph's read-state
and move requests, nested folder listing by path and its limit, Undo, an outage across relaunch, a lost reply,
throttling and server errors, a concurrent Outlook move, incomplete placement
replies, a deleted message or folder, missing folder roles, a read-only grant,
actions Microsoft lacks, search across folders and pages, and that changes reach only
the connection that showed the message. Registration-flow tests connect Microsoft mail as a Google or Apple
account's first mailbox without asking Google for mail, and cover cancellation, refused
consent, a missing mail scope, an unavailable mailbox and reauthorization. Both
hosts' rendered tests connect Microsoft mail first and show its Inbox.

Sending tests in `packages/mail-core/test/microsoft-send.test.ts` send a threaded
reply with an inline image, an attachment and Bcc once after the Undo Send Window and
parse it with an independent MIME parser. They keep a lost answer unknown through
relaunch until Sent Items holds its copy, never sending it twice. Incomplete pages
and multiple matching copies retain the unknown outcome. They also map refused
grants, refusals, size, throttling, unreachable Microsoft and server errors to the
Outbox's outcomes without changing the connection; a refused grant asks for
Microsoft again. Send refuses a message over Graph's limit that Gmail would accept.

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
first, then adds Gmail.

These are deterministic and mocked evidence. Real Microsoft authorization, tenant
restrictions and Graph transport on packaged hosts remain release checks, as do
confirming that Microsoft keeps a sent message's Message-ID in Sent Items (otherwise an
unknown outcome safely stays unknown), Bcc and threading in Outlook, and native
iPhone, iPad and Mac send journeys, in
[#637](https://github.com/unwired-dev/product/issues/637) and the launch
qualification [#855](https://github.com/unwired-dev/product/issues/855).
