# Microsoft mail

[#634](https://github.com/unwired-dev/product/issues/634) connects a personal
Outlook.com or work/school Microsoft 365 mailbox as a **Mailbox Connection** and
reads its Inbox through Microsoft Graph on iPhone, iPad and Mac. It is mailbox
authorization only: Microsoft never becomes a Product Sign-In, and a Google or
Apple Product Account adds Microsoft mail without any Gmail grant. Microsoft
Product Sign-In and linking remain [#633](https://github.com/unwired-dev/product/issues/633).
Shared and delegated mailboxes are outside the [launch scope](product/power-user-launch.md).

## Connecting

After Google or Apple Product Sign-In and any [device admission](private-product-sync.md),
nothing asks a provider for mail. The account page shows **Connect your mail** with
**Authorize Gmail**, **Choose another Google mailbox** and **Connect Microsoft mail**.
A Google sign-in only suggests its own account to Gmail; it is never a Microsoft hint.

**Connect Microsoft mail** opens Microsoft's sign-in page in the system web
authentication session and asks for `offline_access User.Read Mail.Read`. The
connection is shown only after Graph reads the account and its Inbox:

| Outcome                                                           | What the person sees                                               |
| ----------------------------------------------------------------- | ------------------------------------------------------------------ |
| Cancelled sign-in                                                 | **Mailbox authorization was cancelled**; the Product Account stays |
| Consent refused, or a grant without `Mail.Read`                   | **Mail access was not granted**                                    |
| Tenant restriction, admin consent required, or no Outlook mailbox | **Microsoft mail is unavailable for this account**                 |
| Network or Microsoft service failure                              | **Mailbox authorization was interrupted**; retry resumes           |

Each outcome keeps the Product Account and offers retry or another provider,
including after relaunch. Once connected, the account page's **Mailboxes** section
lists Gmail and Microsoft connections together and offers **Add a Microsoft mailbox**.
A connection whose grant Microsoft refuses later shows **Microsoft needs your
permission again** and **Allow Microsoft access for** its address. Authorizing it
again suggests that account and must name the same Microsoft account; another
account is added separately. Removal works as for [Gmail mailboxes](gmail-inbox.md#gmail-mailboxes)
and leaves the mail in Microsoft.

## Reading the Inbox

The Microsoft Inbox joins the unified Inbox with the same encrypted mailbox cache,
body cache, remote-content and attachment rules as Gmail. Synchronization follows initial listing and delta continuation pages. The initial
cache retains the newest 200 Inbox messages; each later synchronization updates
new or changed messages, read state and messages that left the Inbox, and saves
the newest delta link Graph returns even when nothing changed. An
interrupted delta round resumes after relaunch. Losing a message from a full cache
admits the next older one. Expired delta state restarts synchronization while
saved mail stays visible; repeated expiry offers retry. This slice does not claim
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

Not yet available for Microsoft mail: organizing actions and online search
([#635](https://github.com/unwired-dev/product/issues/635)) and sending
([#636](https://github.com/unwired-dev/product/issues/636)). Saved-mail search
covers Microsoft messages; online search skips Microsoft mailboxes, and the
composer offers only Gmail mailboxes as senders.

## Credentials

Microsoft tokens must stay device-local, outside Product Sync, JavaScript and logs.
Other Trusted Devices learn the connection's provider and removal through encrypted
Product Sync, but each device authorizes the mailbox itself. Requests must be
limited to the signed-in person's own mail over authenticated HTTPS; a Microsoft
credential must never reach Gmail or another host. The reviewer-only
[architecture companion](architecture/microsoft-mail.md) records adapter evaluation,
credential custody and synchronization mechanisms.

## Configure the hosts

Register a public-client application in Microsoft Entra ID that accepts personal
Microsoft accounts and work or school accounts. Add the iOS/macOS redirect URI
`msauth.dev.unwired.mail://auth`, which both hosts share through the
`dev.unwired.mail` bundle ID, and the delegated Microsoft Graph permissions
`User.Read` and `Mail.Read`. Set the application ID when generating each host:

```sh
UNWIRED_MICROSOFT_CLIENT_ID='<application (client) ID>' \
  mise exec -- pnpm native:generate
```

The variable is optional: without it the hosts still offer **Connect Microsoft
mail**, which reports **Mailbox authorization was interrupted**. TestFlight uploads
read it from the root `.env.local` or the `MICROSOFT_GRAPH_CLIENT_ID` repository secret.

## Deterministic evidence

Shared tests drive the Microsoft Inbox through a controlled Graph mailbox: the
first list and delta round, later changes after relaunch, partial and repeated delta identities, an expired delta link,
refilling a full cache, an HTML body with an inline image, an attachment download
by its decoded size, hidden/unreferenced images, optional image and attachment-metadata failures with
retry after relaunch, a refused grant, and a unified Inbox where only Gmail searches
online and sends. Registration-flow tests connect Microsoft mail as a Google or Apple
account's first mailbox without asking Google for mail, and cover cancellation, refused
consent, a missing mail scope, an unavailable mailbox and reauthorization. Both
hosts' rendered tests connect Microsoft mail first and show its Inbox.

The hosted native suite stores a Microsoft connection beside Gmail, publishes its
own Product Sync descriptor, exercises the real token exchange, refresh and Graph
verification adapter with controlled HTTP responses, refuses Graph URLs outside the person's own mail and
Gmail requests with a Microsoft credential, and marks only its descriptor removed.
The `registration-apple` native journey connects the synthetic Microsoft mailbox
first, then adds Gmail.

These are deterministic and mocked evidence. Real Microsoft authorization, tenant
restrictions and Graph transport on packaged hosts remain release checks in
[#637](https://github.com/unwired-dev/product/issues/637) and the launch
qualification [#855](https://github.com/unwired-dev/product/issues/855).
