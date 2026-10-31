# @private-email/mail-core

## 0.1.0

### Minor Changes

- edac772: Browse a Gmail mailbox's labels, All Mail, Spam and Trash from the Mailboxes
  sidebar on iPhone, iPad and Mac. Each view lists its newest 200 messages from
  the encrypted cache, stays current through Gmail history across relaunch and
  offers the organizing actions with the view's own meaning: Move to Inbox in Trash
  and Spam, including the iPhone Reply sheet, and Move to from a label replacing
  that label. Reader actions follow the Inbox fallback after a label is removed,
  and row actions close a reader only when they remove mail from its opened view.
  Share stable Gmail view list entries through the mailboxes entry point.
- 07d8147: Browse a Microsoft mailbox's Sent Items, Archive, Junk Email, Deleted Items and
  own folders from the Mailboxes sidebar on iPhone, iPad and Mac. Each folder lists
  its newest 200 messages from the encrypted cache, stays current through its own
  Graph delta link across relaunch and offers the organizing actions, with Move to
  Inbox in Deleted Items and Junk Email. A folder Microsoft could not read keeps its
  saved mail, and a folder removed in Outlook leaves the sidebar.
- 3184c0f: Add unified Sent, Archive, All Mail, Spam and Trash under Favorites on iPhone, iPad
  and Mac. Each interleaves the matching Gmail label, Microsoft folder or IMAP
  special-use folder of every connection in the window's Profile, names each row's
  mailbox and offers that connection's actions. A connection without the role shows
  as not included instead of being guessed from folder names.
- b5bd44a: Load Remote Message Content in IMAP mail on iPhone, iPad and Mac. The IMAP reader now
  follows the device's remote content policy and the connection's own setting, which
  Settings offers for IMAP mailboxes too, with the same **Load images** consent,
  Authorized Remote Content Cache, tracking-pixel blocking and shared display budget as
  Gmail mail. `createImapInbox` accepts its `connection` and exposes `loadRemoteImages`
  and `forgetRemoteImages`; `NativeImapMailbox` includes the remote content cache calls,
  and the controlled `testing/imap-mailbox` fixture serves remote images. The reader's
  "not loaded yet" notice for IMAP mail is removed.
- 0c7e666: List, download, open and share received attachments of IMAP mail on iPhone, iPad and Mac, with the same rows, limits and protected local storage as Gmail. Downloads read the message source again at its folder's UIDVALIDITY, and a folder synchronization that records a new UIDVALIDITY deletes saved attachments of the folder's earlier messages, including downloads in flight.

  Gmail, Microsoft and IMAP Inboxes now share one attachment download implementation.

- 8eb88f2: Recent IMAP mail reads offline without being opened first. After each Inbox
  synchronization, iCloud Mail, Fastmail and other IMAP connections save the bodies of
  the newest Inbox messages from the last 30 days, within the shared body-cache budget
  and with Gmail's prefetch limits, pauses and failure handling. A header-only read
  chooses which messages to download, so only single plain-text or HTML messages are
  saved and no attachment is downloaded speculatively; other messages stay on demand.
  Opening a message waits for its prefetch instead of reading it twice, a new
  UIDVALIDITY keeps no body read before it, and local search reports prefetched bodies
  as saved. `NativeImapMailbox` gains `imapHeaders`, which the native Registration module
  implements over SwiftMail. Body admission accepts an optional `expectedRevision`;
  IMAP supplies it so a concurrent metadata commit fences stale body writes atomically.
- ecdc0ee: Star IMAP mail with the server's `\Flagged` flag from the reader, Inbox rows, context menus and the Command Palette on iPhone, iPad and Mac, and see stars set in other mail apps. Mail in an IMAP connection's Trash or Spam folder offers Move to Inbox instead of Archive, Move to Trash and Report spam, as Gmail's does.
- 5bbede1: IMAP mail can be answered. On iPhone, iPad and Mac the reader offers Reply, Reply All
  and Forward for a message from an IMAP connection with verified SMTP, as for Gmail; a
  receive-only connection offers none. The Draft sends from the receiving connection
  with In-Reply-To and References headers and the quoted correspondence, and Forward
  carries the received attachments. Saved IMAP bodies now keep the headers a response
  needs; a body saved before them is read from the server again when opened. `ImapInbox`
  gains `responseSource`, and a reply's `response.thread` is optional because IMAP has no
  conversation to join.
- a1c0ccb: Add the Profile Switcher to every window's sidebar. Its system menu lists each
  Mail Profile with its connections and unread mail, switches only that window,
  and names a new Mail Profile, explaining when another device must update first.
  The Default Profile appears as Primary Profile. Windows open a targeted link's
  Profile, then the one they restore, then the device's Startup Profile: AppKit
  restores each Mac window with its Profile, and the iPhone and iPad window
  restores the Profile it last showed.
- ee887ce: Add Settings › Mail Profiles on Mac, iPhone and iPad, opened from the Profile
  Menu's Manage Mail Profiles…. It lists every Mail Profile with its connections
  and the Startup Profile, adds a Mail Profile, renames the selected one (the
  Primary Profile keeps its name), and chooses the device-local Startup Profile
  that new windows open.

  Profile creation and renaming wait for registration verification; changing Startup
  Profile preserves every already-open window. Each Product Account keeps its own
  Startup Profile on this device.

  Match the approved Profile row disclosures and Add action tint, and keep Profile
  name editing and the mobile Startup Profile picker at the platform's minimum
  interaction size.

- 4b9a4b8: Move a mailbox between Mail Profiles and remove a Mail Profile from Settings ›
  Mail Profiles on Mac, iPhone and iPad. Each mailbox of the selected Profile has a
  system pop-up naming its Profile; Remove Mail Profile… asks first and, once
  confirmed, removes the named mailboxes this device still lists in the Profile
  from every Trusted Device. The registration store's `removeProfile` accepts the
  confirmed connections to remove before the Profile, and refused moves and
  removals explain their reason.

  On iPhone and iPad, long mailbox addresses truncate on one line beside the Profile
  pop-up while its accessibility label keeps the full address. Profile pop-ups keep
  a 44-point minimum touch target even for short Profile names.

- 98b2991: Notify privately for newly arrived Inbox mail from IMAP and Microsoft 365 mailboxes too (#1094). Settings › Notifications lists a switch for every mailbox. IMAP notifies for unread mail at or above the last committed UIDNEXT under an unchanged UIDVALIDITY, received no earlier than the previous synchronization began (less five minutes for provider clocks), so older mail moved in never notifies. Microsoft notifies for unread mail a delta page names that this device had not cached; Graph creates moved mail anew in the Inbox, so it counts as created there unless it is older than a full cache. Listings, a UIDVALIDITY change, an expired delta link and updates to known messages never notify. Mark as Read on a notification acts on IMAP and Microsoft mail as on Gmail, and so does Archive, except that on IMAP it needs the server to declare an archive folder and move without expunging other mail; otherwise it changes nothing.
- b139883: Keep the bodies of older Gmail messages opened from downloaded history, so they reopen offline after a relaunch (#1385).

  - **Kept with history:** opening a message revealed from downloaded history saves its body in the Bounded Encrypted Body Cache, within the same budget, eviction order and working-set protection as other opened bodies. The mailbox document names those bodies, so pruning no longer removes them for being outside the recent cached views.
  - **Removed with the message:** the body leaves the device when Gmail reports the message deleted or outside All Mail, or when a new pass after an expired history ID completes without listing it.

- 52a62f7: Show when the Inbox was last brought up to date on iPad and Mac (#1444).

  - **Subtitle:** when the shown mailboxes are neither syncing nor offline, the iPad and Mac Inbox subtitle adds how long ago they were last brought up to date, such as `12 unread · Updated just now` or `Updated 5 minutes ago`. With several mailboxes shown, the oldest last update counts. iPhone's one-line subtitle leaves it out.
  - **Recorded per connection:** Gmail, Microsoft and IMAP connections save when their latest completed synchronization started with their encrypted cache, so the time survives relaunch and later failed attempts. Each successful synchronization saves the time, even when no mail changed.

- fe54ada: Duplicate a Mail Profile from Settings › Mail Profiles on Mac, iPhone and iPad.
  Duplicate Mail Profile creates `<name> Copy` without asking, selects it and
  shows its page for renaming. It copies only the name; mailboxes, sign-ins, mail
  and Drafts stay with the original. A Profile that owns no mailboxes now says so
  in its Mailboxes group and points to moving one from its current Profile.
  Creating a Mail Profile now resolves with the new Profile's identifier, so
  Duplicate opens its own copy even when another creation finishes first.
- 8e90910: Synchronize an optional Mail Profile Color and Icon inside the end-to-end
  encrypted Profile record. The registration snapshot's Profile list carries each
  Profile's known `color` and `icon`, `createProfile` accepts a style, and the new
  `restyleProfile` changes a published Profile's style through compare-and-set or
  keeps it for a Profile named offline. Older records and keys this client does
  not know read as Graphite and First Letter, and rewrites keep the stored keys.
  The snapshot omits the default style. Edits to an unpublished Profile's style
  survive delayed publication, relaunch and retry conflicts. Duplicate Mail Profile
  copies the Color and Icon with the name.
- d30a3e6: Add Proofread, Break into Paragraphs, Expand Text, Shorten Text, Make More
  Friendly and Make More Neutral to the Mac composer's Writing tools menu, grouped
  as the approved design shows. Each runs its own on-device model operation on the
  selection or the whole authored body and opens the same review panel as Rewrite,
  under its own title. The assistance core exports `textTools`, `TextTool` and
  `isTextTool`; `rewriteInput` takes the tool, and `NativeAssistance.rewrite`
  receives each tool's operation in its request. The Mac pop-up control accepts
  item sections separated in its menu.
- d0de90a: Mac Settings › Mail Profiles chooses a Profile's Color and Icon from system
  pop-ups after its name, and lists each Profile with its styled monogram: a
  circle in its Color with its Icon or first letter in white. The Primary Profile
  shows Graphite and First Letter. Shared mail-core adds the Profile Color tokens
  (`profilePalette`), the ordered `profileColors` and `profileIcons` with each
  Icon's SF Symbol, and a `restyle` refusal. Native pop-up menu items accept a
  `symbolColor`.
- a6c02e1: Search the Inbox mail saved on iPhone, iPad and Mac by sender name, address or subject, across all Gmail mailboxes or within one. Search reads only this device's encrypted cache, so it works offline and asks Gmail nothing. Each result opens in the reader and says whether its body is already saved on this device or downloads from Gmail when opened. A slower answer for an earlier search never replaces the current results, and a removed mailbox's mail leaves them at once.
- 71e8349: Search Gmail online from the Inbox on iPhone, iPad and Mac. After a search of the mail saved on this device, **Search Gmail for “…”** asks Gmail's own full-text search of the chosen mailbox or of every mailbox, shows the results under **From Gmail** below the saved results, and pages further with **More from Gmail**. Results outside the cached Inbox open in the reader without being saved on this device. A mailbox Gmail cannot search explains why while the other results stay, and an answer for an earlier query, view or Product Account is never shown. Gmail search queries keep a literal `+`.
- e4b6969: Download, open and share received Gmail attachments on iPhone, iPad and Mac (#610).

  - **Listing:** an opened message lists its attachments with names, sizes and availability, without making attachment requests. Rows appear 20 at a time with Show N more for the rest. Gmail can include small attachment bytes in the bounded MIME response needed to open the body; the cache retains only descriptors. The list is kept with the encrypted body, so it also shows offline. Names cannot leave their folder. Very long sender names are reduced before Unicode cleanup. Shortened names keep a short final suffix or use underscores for dots, so an earlier suffix cannot become the file extension.
  - **Download:** each attachment downloads only when asked, through its own mailbox's Gmail connection. It is kept only when its bytes decode to exactly the declared size; incomplete or damaged copies are refused. Downloads can be cancelled and retried, and attachments over 25 MiB are listed without a download.
  - **Open and share:** a downloaded attachment opens in the system's Quick Look preview, or shares through the system share sheet, with only that file.
  - **Cleanup:** downloaded files stay in private Application Support storage, outside backups, bounded to 250 MiB with oldest-file eviction. Reader, message and Inbox cleanup waits until active Quick Look previews and shares finish; those files also stay through eviction and count toward the limit. A download that cannot fit around them can be retried after the presentation ends. Mailbox removal, sign-out, account deletion, device removal and relaunch delete files immediately.

- dfc1f46: Preserve Draft files through attachment-only Close, Undo after image import and
  Discard racing a later edit. Clean abandoned or failed picker copies and keep
  received-attachment creation from changing a newer navigation destination.
- dfc1f46: Add files and inline images to Drafts on iPhone, iPad and Mac. iPhone and iPad attach files and photos through the system pickers, insert a photo inline at the caret, and paste images; Mac attaches through the open panel, attaches dropped files and places pasted images inline. A Downloaded Attachment offers **Attach to New Message**, which copies its bytes into a new Draft without keeping the mailbox it came from. Each file's bytes are encrypted on this device for the signed-in Product Account, verified by size and digest, and kept with their Draft through relaunch, Undo and conflicting edits until the Draft no longer uses them or is discarded. An import can be cancelled; a cancelled, interrupted, failed or oversized file stays listed as not added and is never sent, and damaged bytes show as unavailable.
- f6bf0cb: Reply, Reply All and Forward from the Gmail reader on iPhone, iPad and Mac (#613).

  - **Sender:** a response starts a Draft from the mailbox that received the message, and only while that mailbox can send. Choosing another sender keeps the reply's threading headers but not the receiving mailbox's Gmail thread, which returns when the receiving mailbox is chosen again. The thread stays scoped to that mailbox during a concurrent sender edit, including the first save.
  - **Recipients:** Reply goes to Reply-To or From, or to the original recipients of a message the mailbox sent. Reply All adds the other To and Cc recipients once each, without known Gmail identities belonging to the account unless addressed to the sender alone. Groups and commented headers keep their valid members, and invalid entries are left out.
  - **Threading:** replies keep `Re:` subjects, the Gmail thread, In-Reply-To and up to 20 References, including single-parent ancestry when References is absent. Forwards keep `Fwd:` subjects. Opened bodies now keep their addressing and threading headers.
  - **Quoted text:** the answered message's readable text stays apart from the authored body, read-only behind Show quoted text.
  - **Forwarded files:** Forward downloads every attachment and copies it, with resolved inline images in their original positions and repeated occurrences, into Draft Assets. Files that cannot be copied stay unsendable. Closing the initiating reader, changing accounts or choosing another destination during preparation prevents creation; queued presses start one response.

- 1ccb9af: Synchronize Drafts and their files between a Product Account's Trusted Devices
  through End-to-End Encrypted Product Sync. Conflicting edits and edits racing a
  deletion are kept as conflict copies, files download verified on first use and
  stay visibly incomplete until they do, and Convex stores only sealed records and
  file chunks.

  Discard retains encrypted cloud assets for offline conflict recovery until Product
  Account deletion. Interrupted uploads retry before complete references publish,
  and sealed deletion tombstones prevent previously observed records from replaying.

- 506964e: Send a Draft from the composer on iPhone, iPad and Mac. A sent Draft waits in the
  Outbox for a 10-second Undo Send Window, is claimed through Convex under an opaque
  identifier so only one Trusted Device can submit it, and is handed to Gmail
  as a formatted message with its files, inline images and reply threading. The
  Outbox shows messages waiting to send, refused ones to edit, and handed-off ones
  whose outcome is unknown, which are never sent again automatically.

  A mailbox refresh that prevents handoff keeps the message waiting to retry with
  its held claim, as does a retryable Gmail refusal such as a rate limit.

  If a mailbox changes its address, the composer keeps the Draft's chosen From
  address visible and asks for the mailbox to be chosen again. Queued messages
  stop before Gmail handoff if their chosen sender is no longer available.

  The composer is read-only while Send is pending and becomes editable again if
  admission is refused. Send dismisses any open translation or writing-help preview
  and prevents new requests while admission is pending.

- 8e745d8: Recover interrupted and uncertain Outbox deliveries. A message whose Gmail
  handoff had no answer is looked up in Gmail's Sent mailbox by its MIME boundary
  when it becomes unknown, when the app starts or becomes active, and on
  **Check Again**; exactly one match records it as sent, and anything else keeps it
  unknown without resending. **Edit** on an unknown message warns that Gmail may
  already have sent it before returning it to the Drafts.

  Sent checks also recover locked storage, device removal and refused Gmail access,
  showing the authorization action even after an offline retry while keeping the
  delivery outcome unknown.

  A Sent check interrupted by a mailbox refresh resumes once the mailbox is ready,
  including when readiness returns before the interrupted answer. Overlapping
  **Check Again** requests share the running lookup.

- 3beb5f5: Keep Gmail fresh across app lifecycles. On Mac, synchronization continues every five minutes after the last window closes and stops on Quit, with no helper process. On iPhone and iPad, a five-minute fallback poll runs while active, a background task synchronizes during the refresh opportunities iOS grants, and becoming active always catches up. Each run verifies registration and resumes from each mailbox's committed checkpoint. A shared wake-hint handler reads only a hint's opaque route and synchronizes only that mailbox. It never keeps Gmail's history ID or address, and ignores unknown or removed routes.
- 0c85d0a: Notify privately for newly arrived Gmail Inbox mail on iPhone, iPad and Mac (#619). Settings › Notifications shows this device's notification permission, an off-by-default choice to show sender and subject, and a switch for each Gmail mailbox that synchronizes end-to-end encrypted to every Trusted Device. Only unread mail Gmail reports as newly added to the Inbox notifies, once, after it is saved; listings, backfill and moved mail never do. Tapping a notification opens its message.

  Unreadable synchronized policies turn notifications off locally and cannot be overwritten. Refused changes show the latest learned policy and feedback on the mailbox's row; concurrent changes are handled without logging a registration failure.

- 3afd931: Summarize an opened message on device on iPhone, iPad and Mac (#620).

  - **Explicit and local:** the reader offers Summarize once a message body is on the device. The summary reads only its subject and readable text, cut at 6,000 characters with a notice when the message was longer, through Apple's on-device system language model. It makes no Gmail request and has no cloud fallback.
  - **States:** the reader shows progress with Cancel, the summary as an unsaved preview beside the unchanged message, and why a summary is unavailable: an ineligible device, Apple Intelligence turned off, a model still getting ready, or an unsupported language. Refusals and failures have their own messages, and the message stays readable in every case.
  - **Stale results:** opening another message, switching mailbox or account, or a changed body cancels the request and drops its result. Nothing is stored or written to mail.
  - **Mock Mail Sessions:** their assistance provider follows the native contract with fixed outcomes, and every selected native mock build returns the same synthetic summary.

- a39391a: Rewrite Draft text and suggest replies on device on iPhone, iPad and Mac (#621).

  - **Rewrite:** the composer's Rewrite action rewrites the selected text, or the whole authored body when nothing is selected, through Apple's on-device system language model.
  - **Suggest reply:** a Reply or Reply All Draft can ask for one suggested reply built from its authored text, its To and Cc display names and its already-local quoted message, cut so the complete JSON request, including escaping, stays within 6,000 characters. It never reads recipient address fields or Bcc, drops any address in names or quoted text, makes no Gmail request and has no cloud fallback.
  - **Recipient context:** reply suggestions consider only the first 100 To/Cc recipients in To-then-Cc order and a 500-character name prefix, so large address-only recipient lists cannot stall name collection.
  - **Review first:** the result is an unsaved preview. Replace text or Use reply replaces exactly the captured text as one edit that one Undo reverts, without changing recipients, the sender, the subject, quoted text, attachments or delivery state. Keep original closes it, and nothing is ever sent.
  - **States:** progress with Cancel, refusal, failure and each unavailable reason leave the Draft unchanged. Authored text whose encoded request exceeds 6,000 characters or has Inline Images is refused with guidance. Editing the body or admitted reply context, changing accounts or closing the Draft cancels the request and drops its result.
  - **Mock Mail Sessions:** fixed synthetic rewrite and reply outcomes, matched by every selected native mock build.

  - **Structured model input:** rewrites, replies and message summaries carry an explicit operation and separate JSON fields, so correspondence cannot impersonate request framing. Summaries shorten their context to fit the encoded bound; authored Draft text is preserved in full or refused.
  - **Safe text replacement:** rewrite, reply and translation results containing image placeholder characters fail without changing the Draft, rather than applying text the editor would drop. Reader translations reject these invalid results too.

- 0668ad3: Translate an opened message or selected Draft text on device on iPhone, iPad and Mac (#622).

  - **Explicit and local:** the reader offers Translate once a message body is on the device, and the Draft toolbar offers it for selected text. Nothing runs until a target language is chosen from the languages the device's Apple Translation supports. Translation reads only the local text, makes no Gmail request, uses installed languages only and has no remote fallback or download.
  - **Reader:** a translation is a read-only, unsaved preview beside the unchanged message, naming the source and target languages. Message text is cut at 6,000 characters with a notice.
  - **Draft:** a translation is reviewed first and applied only with Replace selection, as one edit one Undo reverts. Recipients, subject, attachments and delivery state never change, and selections over 6,000 characters are refused rather than cut.
  - **Stale results:** cancelling, opening another message, switching mailbox or account, or editing the Draft body cancels the request and drops its result. Unavailable languages explain why and leave mail usable.
  - **Mock Mail Sessions:** their translation provider follows the native contract with fixed outcomes, and native mock builds return the same synthetic translation.

- e135c7c: Connect IMAP mailboxes and read their folders and messages on iPhone, iPad and Mac.
  **Connect your mail** and the account page's **Mailboxes** section now also offer
  iCloud Mail, Fastmail and another IMAP server. An IMAP connection shows its reviewed
  endpoint before connecting, uses implicit TLS with verified certificates, keeps its
  password in this device's Keychain and stays receive only until SMTP is added. A
  refused, unreachable or insecure server keeps the Product Account and resumes setup
  after relaunch; a refused password is entered again on the account page.

  iCloud Mail retries a refused name-part login once with the full address. Native
  IMAP projections require a valid endpoint for password repair, and shown rows of
  still-selectable evicted folders survive Inbox reloads while their connection remains open.

  IMAP mail synchronizes by folder, UIDVALIDITY and UID into the encrypted cache,
  resumes from its committed checkpoint, and joins the unified Inbox of its Mail
  Profile; choosing an IMAP mailbox on its own shows its folders. Missing or zero
  UIDVALIDITY refuses message reads and cache admission. The reader shows the
  sanitized body and inline images; remote content stays blocked and attachments are
  counted only. `MailProvider` gains `imap`, and `MailGrantProvider` names the
  providers authorized through their own sign-in. `@private-email/mail-core` exports
  `imap-inbox`, `imap-setup` and a controlled `testing/imap-mailbox` provider fixture.
  Local search reports actual IMAP body-cache availability. Folder refresh failures
  keep cached rows with a warning, and a removed folder choice falls back to Inbox.
  Both hosts share the exported `imapFolderName` and `imapFolderFailed` projections.
  Case variants of `INBOX` use one folder identity; other folder names stay distinct.
  Successful folder synchronization prunes bodies of expunged or UIDVALIDITY-reset
  messages while retaining saved bodies for rows still shown from an evicted folder.
  Successfully saved folder listings also retire cached mail and views for removed
  or non-selectable folders. Failed listing commits preserve shown rows; oversized
  lists and unavailable namespace discovery retain prior cached mail for retry.

- 02bb862: Organize, search and refresh IMAP mail. Messages from iCloud Mail, Fastmail and other
  IMAP servers can be marked read or unread, archived, moved to Trash or Spam (the
  folders the server declares by role), moved to any other folder, and moved back with
  Undo. Changes are saved on the device and sent to the server in order, surviving
  outages and relaunch; COPY fallback records its destination before deleting the source. An uncertain
  move without that record waits for explicit discard and is never replayed. A message
  another client moved, a recreated folder, a changed role mapping or a removed destination
  shows as the server has it. Servers without MOVE or UIDPLUS offer only read state.

  Online search also asks each IMAP server, covering up to 50 folders including the Inbox
  without Trash and Spam, and says when folders or older matches were left out. Its copy
  no longer names Gmail. IMAP servers that advertise IDLE report new mail while the Mac
  app runs and while the iPhone or iPad app is active.

- ebcb577: Send from iCloud Mail, Fastmail and other IMAP mailboxes through their SMTP server.
  Connecting or entering the password again now verifies SMTP on its own: iCloud Mail
  uses STARTTLS on 587 and Fastmail SSL/TLS on 465, and another server's form adds its
  SMTP server, port, SSL/TLS or STARTTLS, and an optional separate user name and
  password. A mailbox connected before this stays receive only until its password is
  entered again.

  Messages keep the Outbox's Undo Send, claim and recovery rules. SMTP refusals before
  acceptance are kept apart from an uncertain outcome, which is never sent again
  automatically. After SMTP accepts a message, a copy with its Bcc field is filed in the
  folder the server declares as Sent; filing again after a lost answer or relaunch finds
  that copy instead of adding another, and never resends the message. A mailbox whose
  server declares no Sent folder cannot send.

- a182684: Connect and read Microsoft mail on iPhone, iPad and Mac. Product Sign-In with Google or Apple no longer starts Gmail consent on its own: **Connect your mail** offers **Authorize Gmail**, **Choose another Google mailbox** and **Connect Microsoft mail**, and the account page adds **Add a Microsoft mailbox**. Microsoft actions appear only when the build has a configured Microsoft client ID or a mock provider. A personal Outlook.com or work/school Microsoft 365 mailbox connects through Microsoft's sign-in with read-only mail access, without any Gmail grant, and its Inbox joins the unified Inbox through Microsoft Graph: the newest 200 messages first, then delta changes, with bodies, inline images and attachments read on demand into the same encrypted caches. Cancelled or refused consent, tenant restrictions, an account without an Outlook mailbox, expired delta state and a refused grant each keep the Product Account and show a state to retry or authorize again. A grant refused while reading attachment metadata still asks for authorization when the message also exceeds the MIME metadata budget. Organizing, online search and sending stay Gmail-only for now.

  Microsoft messages without a usable conversation ID stay separate in the Thread view; messages sharing a conversation appear newest first. Malformed native capability replies keep Microsoft authorization unavailable without failing setup.

- a182684: Expose the registration record schema and mailbox descriptor type through the synthetic
  registration vault testing entry point so Product Sync fixtures use the public test contract.
- e9230a2: Organize and search Microsoft mail. Outlook.com and Microsoft 365 messages can be
  marked read or unread, archived, moved to Deleted Items or Junk Email, moved to one
  of the mailbox's own folders (nested ones included, shown by path), and moved back
  with Undo. Changes are saved on the device and sent to Microsoft Graph in order,
  surviving outages, throttling and relaunch, and a message or folder removed in
  Outlook shows as Microsoft has it. Online search covers every folder of each
  Microsoft mailbox beside Gmail's.
  Writes wait for current Trusted Device verification.

  New Microsoft connections ask for `Mail.ReadWrite`. Connections authorized before
  keep reading, and ask for Microsoft permission again the first time a change needs
  it. Organizing copy names the mailbox's provider instead of always saying Gmail.

- e2db13e: Send from Outlook.com and Microsoft 365 mailboxes through Microsoft Graph. Microsoft
  mailboxes are now offered in From, and their messages keep the Outbox's Undo Send,
  claim and recovery rules: the exact message, with its files, inline images, reply
  headers and Bcc, is handed to Graph's sendMail. Only definite non-delivery is retried.
  An accepted message leaves the
  Outbox; an uncertain one is never sent again automatically and is confirmed only from
  one Sent Items copy carrying its own Message-ID. Connecting Microsoft mail now also
  asks for `Mail.Send`; a mailbox connected before keeps reading and organizing, and its
  first refused send asks for Microsoft again. A Microsoft mailbox sends messages of up
  to 3 MB here to fit Graph's 4 MB request limit after base64 encoding.
- 6509f5d: Give every Mailbox Connection an explicit owning Mail Profile. Connections
  recorded before Profiles, which is every connection today, belong to the lossless
  Default Profile without changing any connection, Draft, Outbox or encrypted-record
  identity. Consumers constructing a decoded `MailboxConnection` must supply its
  required `profile`; old-form snapshot JSON remains accepted. Creating another
  Profile remains unavailable.
- 4a4f5cc: Read and search mail through an explicit Mail Profile. Each reading view shows
  one Profile. Native Mac windows currently open Default; mobile message links can
  name another with a `profileId` parameter, retaining it when the reader closes.
  Malformed selectors, a connection owned by another Profile, or an unknown Profile
  show nothing. `inboxMessages` and `createGmailSearch` now take a `{ profile, mailbox? }`
  scope instead of an optional mailbox ID, Inbox listings carry their `profile`, and
  `profileMailboxes` lists one Profile's mailboxes. `readingProfile` decodes
  absent, malformed and repeated `profileId` selectors. Mobile navigation retains
  the window’s Profile through reading, composing and returning to the Inbox. Draft
  senders and reader actions consume #646’s connection-Profile boundaries; the
  unified Inbox creates Drafts from the window’s Profile. Backend/native Profile
  Record Scope routing remains #647 work.

  Gmail and Microsoft Graph reading, cached bodies, attachments and authorization
  notices share that Profile scope. Online provider search remains Gmail-only.

  Reader Mail Assistance uses the reading Profile’s device-local consent, including
  Translation, and cancels retained work when that consent is revoked or the reading
  Profile changes. Account settings and Draft consent retain their staged Default
  Profile paths until #647 supplies their ownership and lifecycle.

- a285337: Keep Drafts and their delivery within one Mail Profile. `profileOf` gives a
  connection's Profile, and `sendingMailboxes` now requires the Profile whose
  senders it lists. The Draft store refuses a sender change into another Profile
  and a received attachment from another Profile, **Attach to New Message** never
  falls back to another Profile's sender, and `startResponse` leaves only the
  sending Profile's addresses out of **Reply All**, so its mailboxes must carry
  `profile`. Storage, Product Sync records and Outbox delivery are unchanged, and
  creating another Profile remains unavailable.
- 043d25c: Prepare both native clients for translated interface text. All interface copy, including registration, private sync, search, organizing, the reader, attachments and the Draft composer, now comes from one shared English catalog with per-key English fallback. The Language control under the Inbox and on the account page offers System default or a saved, device-local override. Dates and file sizes follow the device's regional format, including its calendar, numbering system and 12/24-hour preference, and Mac menus and window titles use the same catalog before JavaScript starts.
- 6ee2629: Removing a Trusted Device now seals the new key epoch separately to each remaining Trusted Device's own encryption key and to a replacement Recovery Key. Nothing the removed device held opens it, not its keys, earlier rings, enrollment secrets or earlier Recovery Keys. Each device binds a long-lived encryption key when it creates the account's keys, confirms admission or first unlocks with the Recovery Key. A bound key is never replaced, and a device that loses its key enrolls again as a new device.

  On iPhone, iPad and Mac, **Remove** now shows the replacement Recovery Key first and asks for its last four characters. Cancelling changes nothing. Confirming removes the device, activates the new epoch and makes the replacement Recovery Key current, all at once, after a recent sign-in. If the account changed meanwhile, a fresh key is shown to save and confirm again. A lost reply keeps the proposal on screen, and confirming again never removes twice.

  Remaining devices no longer have to adopt a removal before it completes. A device that was offline adopts the newest keys directly when it reconnects, without the Recovery Key. Writes sealed at an earlier epoch are refused and sealed again after adopting the new one. The previous Recovery Key stops admitting devices as soon as a removal activates.

  Losing a device encryption key preserves an unconfirmed Recovery Key or unanswered removal until it is settled. Ordinary private sync and enrollment decisions remain unavailable until the installation enrolls again.

- 7aba467: Load a message's remote images on request. Under the default Ask policy, the
  reader explains that loading reveals the device's IP address and when the
  message was opened, and offers Load images for that presentation; Never and
  Always load can be chosen for this device and for each Gmail mailbox on the
  account page. Images load only near the visible part of the message, six at a
  time per message and twelve across the account, through a native HTTPS fetch
  outside WebKit without cookies or credentials that refuses non-public
  destinations, pins one validated address while authenticating the original host,
  and repeats those checks for every redirect. Validated images are kept in a
  separate 250 MB encrypted cache scoped to each account, mailbox, message and
  source, which Clear remote content empties. Known tracking pixels never load.
  IPv6 answers that could translate to a private address are never used; hosts
  reachable only through such addresses keep their images as placeholders.
- 2dae6d7: Register content-free Gmail push wake routes on iPhone, iPad and Mac. After each
  verification, native code registers the APNs token with the relay and keeps a
  Gmail watch and an opaque route for every verified mailbox, renewing it before
  Gmail ends it. Each wake synchronizes only its routed mailbox and completes the
  system's handler. Removing a mailbox stops its watch when no other device needs
  it and removes its route; sign-out and deletion stop watches first. While the Mac
  app is active, its five-minute interval supplements wakes; otherwise it remains a
  fallback until every usable mailbox has a verified route outside the renewal
  window, and resumes when that coverage is lost.

  Register a newly received or rotated APNs token as soon as it arrives after
  restoring the account. Token changes cannot restart watches during sign-out or
  deletion, and a rejected device or deleted account clears its local access. The
  next registration operation closes the account view with its removal notice.

- 3f028f0: Gate every explicit On-Device Mail Assistance action, Summarize, Draft Rewrite and
  Suggest reply, and Translate, behind Mail Assistance Enablement. It defaults off
  on every device, is turned on or off from **On-device assistance** on the account
  page for the Product Account's Default Profile, and is stored only in this
  device's Keychain; sign-out, deletion and device removal purge it. While it is
  off the actions are hidden and nothing reaches Apple's model or Translation;
  turning it off cancels in-flight assistance and forgets shown previews.

  `@private-email/mail-core/assistance-enablement` exports the enablement store, and
  Mock Mail Sessions gain an `assistance-disabled` scenario and a `mailAssistance`
  provider. The hosts' `AssistanceContext` and `TranslationContext` now default to
  no assistance.

  The account page offers an explicit Apple Intelligence availability check only
  while assistance is enabled. It explains unavailable states without generating
  text and discards checks and status when assistance or the account changes.
  Unsaved device choices show saving or failure status and offer a save retry;
  turning assistance off closes the gate even if persistence fails.

- d802688: Add a Thread view to the Expo app at `/thread/[id]?mailbox=`. It stacks every
  locally cached message of the opened message's Gmail thread, newest at the top,
  opens scrolled to the opened message and highlights it. Quoted history in each
  message starts collapsed behind Show quoted text. Gmail's quote container, Apple
  Mail's and Thunderbird's cited blockquotes, an "Original Message" marker and a
  trailing run of `>` lines count as quoted history. The single-message reader still
  shows full bodies.

  Every cached message of the Thread mounts its body at once, and bodies load in
  newest-first mount order within the existing concurrency limits. Bounded
  rendering, viewport priority and off-screen distance ordering remain follow-up work
  in [#862](https://github.com/unwired-dev/product/issues/862);
  an older opened message can wait behind off-screen bodies. This slice does not
  qualify full conversation loading or native scroll anchoring.

- 5fc6fc9: Load Thread bodies by what the reader shows on iPhone and iPad. The opened message loads first, then the messages in view, then the rest by distance from the viewport, and scrolling reorders reads that are still waiting without changing each connection's two concurrent body loads or the device-wide four. After scrolling away, visible messages take priority over the opened message too, and switching Threads puts the current Thread ahead of pending background reads from the previous one. Every message of the Thread is brought onto the device, but only the opened body and bodies within one viewport of the visible range are mounted, so a long Thread no longer creates a body view and rich document for every message at once. The opened message now stays in place while the bodies above it load, until you scroll.
- a3293d1: The iPhone, iPad and Mac apps use the new Graphite palette: a graphite accent for links, tints, focus and unread dots, Apple-style neutral backgrounds, and a quieter selection colour in light and dark mode. Every text colour keeps at least 4.5:1 contrast on the background, sidebar and selected rows.
- fab7a42: Add the Command Palette to the Mac, iPhone and iPad clients. It finds and runs
  the open message's actions (Reply, Reply All, Forward, read state, Star, Archive,
  Trash, Spam and Move to… with its picker), New Message, Search Mail, Inbox and
  Account, with fixed ordering and fuzzy matching. The Mac keeps a command input
  at the top of each window and opens with View › Commands… (Command-P), Up and
  Down, Return and Escape, and a click outside closes it; iPhone opens by a header
  swipe on the Inbox heading, the reader's subject line or the composer's top bar,
  which now stay put while the content scrolls, with a one-time hint and an
  accessibility action; iPad also keeps the input in those headers. On iPhone and
  iPad, Search Mail leaves an open reader or composer before focusing the Inbox
  search field. The palette also stays available on the Account page, with the way
  back to the Inbox.

  On the Mac, Command-P leaves an active link confirmation in control of its
  window until the confirmation closes; other windows keep their palette entry.

  The iPad command input has a 44pt touch target in every header.

- fd7bf6b: Adopt the Graphite & Cinnabar design foundations on iPhone, iPad and Mac. Both
  clients now use the design's Light and Dark colors, spacing, radii and the
  macOS, iOS and reading type ramps. Mailbox and folder filters are chips with
  SF Symbols, blocked remote images show a quiet notice, and the reader's actions
  sit in a Liquid Glass toolbar group.
- 1438300: Rebuild the app shell around a Mailboxes sidebar and a floating search bar (#900).

  Keep the shell's floating sidebar, sidebar toggle and search/New Message controls translucent when combined with the redesigned reader's glass groups.

  - **Mailboxes:** a sidebar column lists **All inboxes** and its unread count, then each Mailbox Connection with its Inbox and unread count and, for IMAP, its selectable folders, and the **Account** page last. It replaces the mailbox and folder chips above the list. On the Mac it is a floating Liquid Glass column that a toolbar button hides and shows; windows at most 900pt wide start without it. On iPad it is the leading split-view column; on iPhone it is one Back away from the Inbox.
  - **Floating bar:** search and **New Message** share a Liquid Glass bar at the bottom of the message list, which rows scroll under. On iPhone and iPad the bar rises above the software keyboard while its search field is in use.
  - **Command Palette:** the Mac window's command bar spans the sidebar, list and reader; the palette's **New Message** follows the floating bar's button, so it is offered only while that button is enabled, and **Search Mail** focuses the floating bar's search field. On iPhone and iPad the Mailboxes title opens the palette by a downward swipe or its accessibility action, and **Search Mail** and **Inbox** bring the message list forward.

  - **Mail core:** export the shared mailbox sidebar projection through `mail-core/mailboxes`, including unread totals, selectable folders, selection, each mailbox's storage or synchronization problem, the IMAP folders whose last read failed, and authorization recovery.
  - **Sidebar status:** a mailbox whose storage is locked or failed, or whose provider could not be reached or needs authorization again, shows a warning beside its Inbox row with the problem as its accessibility value, so the problem is visible while another mailbox is selected. An IMAP folder whose last read failed shows the same warning on its own row, with **Folders could not be listed** as its accessibility value, until it is read again.
  - **Lapsed authorization:** a chosen mailbox whose provider authorization lapses stays chosen, showing its authorization notice and, in the heading, its authorization status, instead of falling back to **All inboxes**, so **New Message** cannot start a Draft from another sender. Any mailbox waiting for authorization keeps its place among the sidebar's mailboxes.

- 172b3cc: Redesign the message list on iPhone, iPad and Mac. Rows are three lines with
  the unread dot, Gmail's star as a flag and the arrival time, grouped under Today,
  Yesterday, Last Week and month dividers. The header subtitle names the shown
  mailboxes with the unread count, Syncing or Offline. Empty, syncing, offline,
  storage and authorization states use the design's No Mail copy, skeleton rows
  and quiet banners with push buttons.

  The default preview occupies one line. iPad uses its own list typography and
  spacing in both orientations. Search headers show the result count.

- 1276608: Redesign onboarding, account setup and device trust on iPhone, iPad and Mac (#907).

  - **Welcome and Sign In:** signed out, the app opens on a deep graphite Welcome with the cinnabar **Continue**. It leads to Sign In: **Sign in with Apple** in Apple's black or white button, then **Sign in with Google**, with the Private Sync fine print and the language choice. Mac and iPad show the brand panel beside the form; iPhone stacks the actions at the bottom and returns to Welcome with **Back**. A removed-device or deleted-account notice opens Sign In directly.
  - **Connect your mail:** the first mailbox is chosen from provider rows: **Gmail**, **iCloud Mail**, **Microsoft 365 and Outlook** when the build supports it, **Fastmail** and **Other IMAP Account**. An IMAP row opens its form in place, and **Cancel** returns to the list. **Choose another Google mailbox** stays below the list. When Microsoft refuses the mailbox, its explanation shows as a warning notice above the providers. **Add an IMAP mailbox** on the account page uses the same rows.
  - **IMAP form:** fields sit in labeled rows, grouped into the account, **Incoming (IMAP)** and **Outgoing (SMTP)**. SMTP security is a pair of choice chips, and blank SMTP credentials show **Same as incoming**. **Cancel** comes before the primary **Connect**.
  - **Trust cards:** **Save your Recovery Key**, **Approve this device**, **Use your Recovery Key**, **Approve a new device** and **Unlock your device** are cards with an icon, a title and description. The four pending trust steps retain their cards on the setup page and in Settings. On iPhone, Save your Recovery Key, device approval and Recovery Key entry keep the deep brand color and large leading title in both appearances. Recovery Keys and approval codes sit on a quiet tile. Trust steps stay together on the existing setup page so approval, recovery, sign-out and account deletion remain available; the frames show separate pages and sheets. Remove Device keeps Settings' confirmation modal and its full safety explanation, with a device icon tile, centered copy and iPhone pill actions. Both hosts name the device in the confirmation title.
  - **Buttons:** setup and trust-card actions use the design's quiet fill, with the accent fill for each step's primary action and destructive text for **Decline**. Other account actions retain grouped Settings controls.
  - **Enrollment codes:** the complete code wraps between monospaced four-character groups, with its original value retained for accessibility and approval.
  - **Mail core:** the theme adds the `appleButton` and `appleOnButton` colors for Sign in with Apple in Light and Dark.
  - **Manual IMAP setup:** the provider row describes compatible IMAP and SMTP providers without promising universal server support.
  - **iPhone setup spacing:** match the approved 24pt side margins and 10pt gaps, and keep the initial heading and final controls clear of the safe area.

- cb69e6d: Match New Mail Notifications to the design (#908). Without sender and subject previews, a notification now shows the app's name with "New mail". Notifications group by Mail Profile and offer Reply, Archive and Mark as Read: Archive and Mark as Read act after unlocking without opening the app, and Reply opens the message and starts a reply.
- 80b3de7: Send Microsoft messages with files larger than Graph's single-request limit, up to 150 MB
  with a body that still fits one Graph request. Before
  its handoff, such a message is saved without its files as an Outlook draft, each file is
  attached from native code (through an upload session when it is 3 MB or larger), and the
  draft is then sent once with the Outbox's existing claim, Undo Send and uncertain-outcome
  rules. A refused or interrupted preparation sends nothing and is tried again, replacing
  any draft an interrupted attempt left; an uncertain send is confirmed only from Sent
  Items by its Message-ID. The Microsoft too-large message no longer names a 3 MB limit.
  Pending cleanup of a known-unsent Outlook draft survives offline Edit and relaunch;
  every upload range requires current device trust.
- e909300: Synchronize Mail Profile definitions and connection ownership through end-to-end
  encrypted Private Sync. The registration store can now create, rename and remove
  Profiles and move a Mailbox Connection between them. A Profile named offline is
  published once Private Sync is reachable. Moving a connection and removing a Profile
  need Private Sync; they report `profile-changed` when another device wrote first,
  and removal reports `profile-in-use` while the Profile still owns a connection.
  Pending Profiles survive authorized re-enrollment after device-key loss. Removal
  fences delayed first publication, and confirmed versions prevent older records
  from reviving a removed Profile or regressing ownership.
  Confirmed reads and writes survive later publication failures and relaunch.

  - The registration snapshot lists the other Profiles (`profilesOf`) and each
    connection's synchronized `profile`.
  - `NativeRegistrationVault` adds `sealProfileRecord`, `openProfileRecords` and
    `recordProfiles`.

  The apps do not offer creating another Profile yet.

- 9aafacb: iPhone's Move picker nests folders beneath their parent, tints their symbols, shows
  unavailable folders dimmed and the Inbox's known unread count, searches by full path, and
  lists the account behind Back. Gmail on iPhone moves through the same picker, with its
  label checkboxes listed under More. IMAP folder listings keep the server's hierarchy
  delimiter.
  Microsoft folder listings preserve path segments so a slash in a folder's own name
  does not create false nesting.
  Microsoft Inbox descendants follow the app's language while custom folder and Gmail
  label names stay literal.
- 76fd227: Redesign search on iPhone and iPad: focusing the search field opens a search mode with Close Search beside the field, results under Top Results with the query's words in bold in each sender and subject, and, in a single mailbox or folder, an All Mailboxes / Current Mailbox choice. Editing or clearing the query keeps search open instead of flashing back to the Inbox. A new Filter button narrows the Inbox to unread mail, mail from today or chosen mailboxes through the Filters sheet, and shows what the Inbox is filtered by. Filters opens as a full-height sheet on iPhone and as a popover above the Filter control in a regular-width iPad window, where the floating bar spans the whole window with a centered 400pt search field. The theme adds the 18pt `radius.popover` token. `matchedRanges` in `mail-core` finds where a query's words appear in a field, matched as search matches them. The shared `filterMessages` projection applies the host's `InboxFilter` settings to validated listed metadata.

  While iPhone search replaces the heading, a downward swipe on its field opens the Command Palette. The field keeps its palette entry methods if private storage locks during search.

- 8d15586: Every device after a Product Account's first now signs in as a Pending Device and joins only when an existing Trusted Device approves its Enrollment Code or the Recovery Key unlocks it. Signing in alone gives a new device no account data, Product Sync, push routing or Gmail authorization. The iPhone, iPad and Mac apps show an enrollment gate instead of "This device cannot join". The gate shows the code with **Check for approval**, offers **Use your Recovery Key**, explains why approval is needed, and allows signing out or deleting the account. A device becomes trusted only after it stores the authorized keys and confirms them.

  After a device removal, new devices can join again. The removed device's own identifier stays refused, and under a new identifier it waits like any other device. While the removal's key rotation is pending, only the replacement Recovery Key admits a new device. Convex now publishes a Recovery Key verifier with each recovery envelope, and the unseen-identifier lock and its identifier migration are removed. Pending Devices are limited to one per installation and three per account, and each ends with its Enrollment Code.

  Convex also removes the Product Sync reads that needed only a Product Sign-In; all Product Sync reads now require a Trusted Device proof. The legacy Swift client can no longer add a second device.

- 84a6f8d: Add Sign in with Apple as a Product Sign-In choice on iPhone, iPad and Mac, continuing into the separate, resumable Gmail authorization. Keep Apple relay addresses as contact information only, never link identities by email, and accept the replacement hosts' bundle IDs as Apple audiences in Convex.
- b45a92b: Compose rich-text Drafts on iPhone, iPad and Mac. **New Message** opens an adaptive composer with the sending mailbox always shown, validated To, Cc and Bcc recipients that refuse duplicates, a subject and a formatted body with headings, lists, quotes, code and inline marks, Markdown shortcuts, and Undo and Redo. Every edit autosaves in order to encrypted storage on this device for the signed-in Product Account; a Draft that cannot be saved stays open. Drafts are listed apart from received mail and reopen after an interruption or relaunch without being sent. A Draft whose mailbox is removed or needs Gmail access again keeps it until another mailbox is chosen. Signing out or deleting the account removes its Drafts from this device.

  Unfinished To, Cc and Bcc text also survives an interruption. Undo and Redo retain earlier recipient typing when correcting text or moving the caret.

- b0b3267: Run the Persistent Inbox and Registration stores as Effect programs with tagged errors. Storage and registration failures are now logged with their cause; Schema causes name the failing path without its value, so no mail content or account data is logged. Persistent Inbox stores no longer expose `dispose`, and the unused `Mailbox` service, `MockMailbox` layer, `listInbox`, `readMessage` and `MessageNotFound` are removed.
- dfab40f: Add Google Product Sign-In and separate, resumable device-local Gmail authorization in both native hosts. Validate Gmail grants before connection, retain accounts after interrupted consent, and keep Google refresh credentials off the backend.
- 7c38123: Link Google and Apple as verified alternate sign-ins for one Product Account. Linking reverifies the current sign-in, issues a short-lived single-use ticket bound to the Trusted Device, and completes only after the other identity signs in recently. It never merges accounts, matches by email or turns a Gmail mailbox into a sign-in. Either provider then opens the same account, and `productAccount:connect` reports its Sign-In Providers and rejects reconnects that would reach another account.
- 819d141: Connect more than one Gmail mailbox on iPhone, iPad and Mac. The account page lists each mailbox with its state, adds another with Gmail consent, and asks before removing one. Adding a Google account that is already connected authorizes it again instead of duplicating it. Each mailbox keeps its own Gmail access, encrypted cache, waiting changes and synchronization, so a refused grant in one mailbox never blocks reading or organizing another. The Inbox shows every mailbox together, newest first in a stable order with each row naming its mailbox, or one mailbox at a time. Removing a mailbox deletes its Gmail access and saved mail from this device, marks it removed in private sync so other trusted devices remove it too, and leaves its mail in Gmail. A mailbox saved before this change keeps its cache and waiting changes.
- 30b173c: Organize Gmail mail from the Inbox on iPhone, iPad and Mac: mark as read or unread, star, archive, move to Trash, report spam, add or remove labels, move to a label, and undo the latest removal. Each action uses Gmail's labels, shows at once and is saved in the encrypted cache while awaiting a result, so outages and relaunches keep saved changes and send them in order later. If only the saved Inbox becomes available before a change can be saved, it rolls back and the Inbox announces that the request could not be saved; reconnect, then repeat it. Confirmation, permanent refusal or an explicit discard removes the pending change. Gmail refusing a change shows the message as Gmail has it and says so; labels changed in Gmail arrive through history. The reader has keyboard-accessible action buttons and label checkboxes, and the Inbox offers Undo after a removal. VoiceOver offers the common actions on each Inbox row and announces every action's outcome. Native code writes the Gmail request and keeps the mailbox credential. A device found removed while organizing opens the account page's removal explanation.

  Competing store instances keep a change pending while its attempt is running, so a later reversal cannot be overtaken by a duplicate write. Completed failures can be retried immediately, including from another instance or after relaunch.

- 15988d9: Persist preview Inbox read state in native encrypted storage. Keep encryption keys and synthetic credentials in device-local Keychain storage, preserve data on storage failures, and share committed changes across independent Mac windows.
- 7048de3: Initialize End-to-End Encrypted Product Sync for a new Product Account. The first Trusted Device creates device-held keys, publishes a Recovery Key envelope through the new `productSync:initialize` mutation, and presents the Recovery Key until its final group is confirmed. Initialization succeeds only for an account with no key material, so a device without local keys for an existing account enters enrollment instead of replacing them. The authorized Gmail mailbox descriptor round-trips as an encrypted record bound to its account, identifier, key epoch and schema.
- ed92255: Add a framework-independent Effect v4 mock mailbox and theme tokens consumed by
  a workspace-managed Expo iPhone/iPad Inbox with native split-view selection.
- ee99e36: Open Gmail message bodies on iPhone, iPad and Mac.

  - **Rich reader:** HTML mail renders in an isolated WebKit view from a sanitized, app-generated document. It runs no page JavaScript, keeps no website data, makes no network loads, and cancels every navigation. Remote images become placeholders, tracking pixels are removed, and visible inline images are shown once their bytes are validated. Plain-text mail, and any message the rich view cannot render, shows as selectable text.
  - **Multiple readers:** windows share the body download while each image presentation stays within the shared budget. Opening another window preserves the document and reading position in existing readers.
  - **Links:** a link opens only after the person confirms its full destination. Suspicious links explain why and offer Copy link or Proceed, and every link is reachable from the keyboard.
  - **Saved bodies:** opened bodies are saved in an encrypted cache on the device, so they reopen offline. After the Inbox is available, recent single-part messages from the last 30 days are prefetched one at a time, yielding to messages the person opens.
  - **Cache limits:** saved bodies are sealed to their mailbox and message and stay within a 500 MB device limit. Opened older bodies are evicted before prefetched ones, and the recent working set is protected as soon as the cached Inbox is interactive. Body storage runs off the main thread; locking or changing the mailbox prevents a suspended read from showing its result. Bodies leave with their message, another mailbox choice, sign-out or deletion.
  - **Unavailable bodies:** a body that cannot be shown says whether it still needs downloading, needs Gmail permission again, or is no longer in Gmail.

- e1d65f9: A device without an available Trusted Device can unlock Product Sync with the
  Recovery Key. It reads the account's recovery envelope and opens it only on the
  device, then adopts the account keys, withdraws its approval request and reads the
  synchronized mailbox list. Gmail still needs its own authorization on that device.
  A wrong or foreign key, or an interrupted attempt, preserves encrypted product
  data and creates no replacement keys. Recovery renews authentication and may renew
  the device's approval request; verified keys saved before an interruption survive
  relaunch. The screen explains that losing every
  trusted device and the Recovery Key leaves encrypted product data unrecoverable,
  and it offers no reset.
- 34651eb: Remove another Trusted Device from the iPhone, iPad and Mac apps. Removal asks for a fresh sign-in and rotates the Product Sync keys, and it replaces the Recovery Key. Remaining devices adopt the new keys. A removed device deletes its account data and credentials when it next connects, including after an Apple relaunch. Saved-account operations check removal before opening sign-in, linking or Recovery Key prompts, so cancelling a prompt cannot retain a removed device's keys or credentials.

  Retrying a removal whose reply was lost shows its adopted replacement Recovery Key. A completion notice applies only to that earlier target; choosing another device preserves the key without claiming that device was removed. Confirm the key before starting another removal.

- 2d82cf4: Sign out of the current device, or permanently delete the Product Account, from the iPhone, iPad and Mac apps. Each action is confirmed first. Sign-out unregisters the device and its push routes, then removes the account's keys, credentials and session data from the device. Deletion asks for a fresh sign-in: with Apple whenever Sign in with Apple opens the account, so its authorization is revoked, and otherwise with Google. Convex adds a recently authenticated `POST /product-account/delete` route, so Google-only accounts can be deleted. Other devices purge a deleted account when they next reach Convex. Mail in Gmail is never deleted.

  Save and confirm an offered Recovery Key before signing out. Interrupted removals stay paused across relaunch and can be retried; acknowledged local cleanup finishes before provider authentication.

  A definite refusal of the first deletion attempt keeps the account usable. Refused retries of an unanswered deletion stay pending until confirmed. If this device learns that Apple also opens the account, its next deletion attempt uses Apple.

- e4bdb26: Show the connected Gmail mailbox's Inbox on iPhone, iPad and Mac. Once setup needs nothing more, launch opens the Inbox; the Account button opens the account page, and Open Inbox returns. The first synchronization lists the Inbox newest first in pages of 50, showing each page as it arrives and keeping the newest 200 messages on the device. Later activations apply arrivals, archiving, deletions and read changes from Gmail history. Every step commits with its checkpoint in an encrypted cache, so relaunch, interruption and expired history neither lose nor duplicate messages. The cached list stays visible while Gmail is checked, when Gmail needs permission again, and when it cannot be reached. Gmail tokens stay in native code, mail metadata stays on the device, and sign-out, deletion and choosing another mailbox remove the cache.
- 6f28fe0: A new device of an existing Product Account asks a Trusted Device for approval and
  shows a one-time Enrollment Code. The trusted device seals the account's Product
  Sync keys to that device with HPKE, using the code as the pre-shared key. Convex
  stores only the request and the sealed approval through the new
  `productSyncEnrollment` functions. It refuses replayed, expired, declined,
  superseded, revoked and mismatched approvals without touching account keys. The
  approved device reads the synchronized mailbox list while Gmail still needs its own
  authorization.

### Patch Changes

- 30829e8: Starting a Draft that fails unexpectedly, for example because a Draft subscriber
  throws, no longer leaves a blank Draft behind. Repeated failed New Message presses
  on iPhone, iPad and Mac no longer accumulate empty Drafts that the next save keeps.
- 2b51737: The shared IMAP Inbox now leaves the Bcc field, with its folded lines, out of
  the copy it submits through SMTP, and native `imapSend` submits the message as
  given. Recipients still see no Bcc recipient, and the Sent copy keeps it.
- b9f0c48: Clients that cannot keep Mail Profiles apart are now fenced out before any Profile is
  published. Each device declares its Mail Profile capability. Convex refuses an account's
  first Profile record while a Trusted Device has not declared it. Once the account holds
  Profile records, it serves Private Sync only to clients that present the capability, so
  older builds must upgrade. Creating, renaming, removing or moving into a Profile now
  reports why it was refused: an upgrade is required, the Profile still owns a connection,
  or another device changed it first.
  An unpublished Profile removed while fenced stays removed when its delayed publication
  arrives empty. If it gains live or unknown ownership first, the stale removal is
  cancelled and the Profile returns without moving its connections into Default.
- 7a9018b: A configured launch on iPhone, iPad and Mac now opens the Inbox when a Trusted Device
  has lost its local keys and only optional Recovery Key entry remains. **Unlock private
  data on this device** stays available in Settings under **Account & Devices**. Recovery
  Key confirmation, an unanswered removal's replacement Recovery Key, device approvals,
  unsaved mailboxes, locked storage and unfinished sign-out or deletion still open the
  account page first.
- f608e2b: While a launch reads the saved registration, the app shows Welcome's breathing seal and **Opening your mail…** instead of Welcome, so an installation with a Product Account no longer flashes Welcome before its Inbox or setup.
- 27d75cc: Keep an Inbox row that an organizing action removes on screen while it collapses and fades, and grow it back from its current height on Undo or when a refused, rolled-back or discarded change returns it, in every window. A scroll, a selection or another action finishes a leaving row; synchronization never moves rows and keeps a scrolled list's topmost visible row in place (#1091).

  Expose the shared organizing-row continuity projection through mail-core/mailboxes so both hosts use the same outcome and placement rules. Rows follow provider message IDs; an IMAP Inbox snapshot now names the ID each verified move started from (`originalIds`). Provider snapshots name the messages with unfinished changes (`organizing`), including an IMAP Undo still moving back, so a restored row stays the same row and a confirmed removal stays quiet even while another message has unfinished work.

  Preserve Undo motion after a failed IMAP destination refresh and ignore a mobile exit completion delivered after the same row has started returning.

  Wait for the native iPhone Inbox column to finish appearing before its row exits, so a slower Back transition cannot conceal the removal.

  Finish leaving rows when notification navigation selects another message, and preserve synchronized message details throughout a later removal. The shared projection takes each row's stable displayed content through `ShownRows.contentOf`.

- 3f6507c: Inbox Filters open in the native SwiftUI sheet on iPhone and compact-width iPad, and in a native popover on the Filter control in a regular-width iPad window. The theme drops the unused `radius.popover` token, since the system popover owns its corner radius.
- f561120: Removing a Trusted Device on iPhone and iPad now asks in the system alert: iOS presents it, moves VoiceOver focus to it and returns focus afterwards, and its message scrolls at large text sizes (#1120). The theme drops `scrimMac`, which only that removed custom confirmation used.
- 844cf27: Return the running download to every caller that asks for the same received attachment, and let Forward await it instead of watching the Inbox for its state.
- 4b314a8: On-device summaries and rewrites ask for the language of the message or authored text (#1164). When it confidently identifies that language, the native binding names it to Apple's model and rejects an unsupported language or a confidently detected output language switch as `unsupported-language`. The preview explains the limitation and mail and Drafts stay unchanged. Rewrite instructions forbid added subject lines, greetings and signatures. The assistance qualification corpus is now version 4, with heuristic checks for language switches and added letter framing. Generated text still needs human review.
- f2d35d2: Deleting a Product Account no longer leaves the device stuck on **Confirm account
  deletion** when Apple refuses the deletion's authorization. Convex now answers that
  refusal as an aborted deletion that kept the account, instead of an unknown server
  failure, and the device returns to the account, saying nothing was deleted, even
  after an earlier attempt whose reply was lost.
- ea786e3: The shared IMAP Inbox now reads the folder list through a short-lived native
  IMAP session: native `imapOpen`, `imapCapabilities`, `imapListFolders` and
  `imapClose` replace `imapFolders`. TypeScript assigns folder roles, recognises
  the Inbox and reads the MOVE, UIDPLUS and IDLE capabilities. Native code runs one
  command at a time on a session and closes it when TypeScript is done, when it
  stays unused, or when its connection generation changes.
- 149d61b: The shared IMAP Inbox now synchronizes folders in TypeScript over a native IMAP
  session: native `imapExamine`, `imapEnvelopes` and `imapFlags` replace
  `imapSynchronize`. TypeScript keeps the checkpoint and UIDVALIDITY reset, counts
  arrivals from UIDNEXT and the folder's message count, and reads the newest window,
  new arrivals and the flags of cached messages. Native code still refuses a folder
  without UIDVALIDITY.
- e953984: The shared IMAP Inbox now searches folders in TypeScript over a native IMAP
  session: native `imapSearch` searches one examined folder of an open session and
  returns its newest matching UIDs and match count, and TypeScript reads their
  envelopes, skips folders the server no longer selects or that lack UIDVALIDITY, and
  says when folders or older matches were left out.
- c6b0be9: The shared IMAP Inbox now plans read-state changes, stars and moves in
  TypeScript over a native IMAP session. Native `imapSelect`, `imapFlags`,
  `imapStore`, `imapMove`, `imapCopy` and `imapExpunge` replace `imapModify`.
  TypeScript checks UIDVALIDITY and presence, chooses MOVE or COPY with
  `UID EXPUNGE`, resumes a saved COPYUID without copying again, and treats a
  command that failed after it was sent as interrupted.
- c509c4b: The shared IMAP Inbox now waits with IDLE over a native IMAP session. Native
  `imapIdle` takes a session handle and reports the kinds of server events it saw,
  and ends when its session closes. TypeScript checks the IDLE capability,
  classifies events as a change, the server closing the connection, or neither,
  and keeps waiting through other events until its five-minute bound. Stopping a
  watch closes its session.
- b337451: The shared IMAP Inbox now finds and files Sent copies in TypeScript over a native
  IMAP session: native `imapSearch` also matches a Sent copy's MIME boundary in the
  Content-Type header, and the new native `imapAppend` appends an Outbox message, read,
  to a folder. TypeScript searches the Sent folder for the boundary and appends only when
  no copy is there, so a lost answer still never files a second copy. The native
  `imapFileSent` and `imapFindSent` operations are removed.
- bbd0635: Renew this launch's Product Sign-In before Mail Profile and notification writes
  after a relaunch: Google renews silently and Apple asks to sign in again, so
  New Mail Profile… no longer fails with an impossible “Try again”.
- 9db4ef4: Secondary text, including section headers, captions and timestamps, uses the approved solid colours: `#4F4F54` in Light and `#B0B0B5` in Dark. These improve contrast on the documented opaque surfaces. Remaining Mac contrast-audit failures, including the Dark sidebar, are tracked in [#1550](https://github.com/unwired-dev/product/issues/1550).
- a35a049: Name reader controls without repeating their role. A blocked image without a description
  shows and reads "Image not loaded" in the app's language instead of showing "Image" under an
  image label, kept to one line within a small sender-sized placeholder, and each message link's keyboard control is named by the link's text or
  destination instead of "Open link: …" and is underlined like other links.
- 5e27303: Add New Label… to the Mac reader's Gmail Labels submenu: a native alert asks for a name, then the label is created in Gmail and applied to the message. Gmail label creation is a new native write that receives only the label's name, and menu submenus can now group their items.
- bb71ffb: On iPhone and iPad, a message sent just before switching apps or locking the device finishes its Undo Send Window and reaches its provider within the background time iOS grants; otherwise it stays queued with its original deadline until the app is active again.
- d65b96e: Settings explains a remote-content choice it couldn't save: the pop-up keeps the saved choice and a warning under the row, announced to VoiceOver, says what is still set until the next change. Clear Saved Remote Content shows Clearing… with an activity indicator, and Check Deletion Status shows Checking deletion status… with an indicator, each disabled while it runs, on Mac, iPhone and iPad.
- 4cda3ac: When storage refuses to return an Outbox message to the Drafts, a toast above the search bar says so with Try Again, and VoiceOver hears it at once. When Check Again finds a message in Sent, VoiceOver hears that it is in Sent, on Mac, iPhone and iPad.
- b7fc9a4: Removing a mailbox in Settings keeps its confirmation open while the removal runs: Remove shows Removing… with an activity indicator, and Remove and Cancel are disabled. If the mailbox could not be removed, the confirmation stays with a warning, announced to VoiceOver, that says it is still connected and, when this Mac, iPhone or iPad is offline, says so; Remove and Cancel are enabled again. A removal that applied before its reply failed closes as removed. If its outcome cannot be read back, the confirmation stays with an uncertainty warning and allows retry without claiming the mailbox is still connected.
- cc0e828: A valid Gmail connection no longer shows **Gmail needs your permission again**
  when the app returns to the foreground during synchronization. While the
  foreground account check verifies the connection again, its mailbox and body
  reads are pending rather than refused, and the saved Inbox stays shown until the
  synchronization after the check. A grant Gmail actually refuses still asks for
  Gmail access.
- e5614a1: Log why a New Mail Notification was or was not posted, without mail content or identifiers.
- d5badea: Gmail mailboxes download the metadata of their whole All Mail history in the background once the Inbox is current, 100 messages per page, into encrypted history segments beside the mailbox cache. The download resumes after relaunch or an interrupted page, keeps later Gmail changes, and starts a new pass that keeps the earlier history visible when Gmail's history ID expires. Scrolling past the newest 200 messages of the Inbox or a Gmail view reveals older downloaded mail without asking Gmail, and the Gmail Inbox state reports downloaded messages, Gmail's total and whether the history is complete.

  Messages outside the saved cached views open on demand without saving their bodies. An open still succeeds if synchronization moves the message out of those views while its body downloads.

- 1c52450: While a Gmail connection's history is still downloading, its All Mail subtitle shows how much has downloaded, such as "41,210 of 86,400 downloaded", and All Mail ends with a "Downloading older mail…" row that names the month the list has reached instead of the note that older mail stays in Gmail.
- 85bbda1: Show the Sync Status Capsule above the iPhone and iPad Inbox bar: it counts
  accounts still updating, measures All Mail's history download, and replaces
  per-mailbox "could not be reached" notices with one attention summary and
  Try Again for the unreachable mailboxes. A Gmail history download paused by a
  failed read now reports `paused` and asks for Try Again instead of showing progress.
  Authorization failures remain in Attention alongside their access-repair notices,
  including when a refresh interrupts an unfinished history download.
- 12d2688: Folding recorded changes into downloaded Gmail and Microsoft history no longer
  places a changed message whose receipt equals a segment's oldest into that
  segment. Such a message may still be held by a later segment the fold has not
  read yet, so an unfinished fold step saved it twice: history progress counted
  it twice and scrolling could show it twice until the fold finished.

  Restored mail at an unfinished pass's oldest receipt remains available offline
  after folding, even when later listing cannot recover that equal-receipt mail.

- aa6fe44: IMAP mailboxes download the metadata of every selectable folder in the background once the Inbox is current, Inbox first, newest first and at most 500 messages per bounded UID-range read, into encrypted history segments beside the mailbox cache. Each folder's download keeps a durable checkpoint under its UIDVALIDITY and resumes after relaunch or an interrupted read; a changed UIDVALIDITY restarts only that folder. Arrivals during or after the download are added and messages expunged meanwhile are removed. History survives eviction of the bounded opened-folder caches, and the IMAP Inbox state reports downloaded messages, the folders' total and whether the history is complete or paused, which the existing sync status shows.
- 7004e1a: Microsoft mailboxes download the metadata of their Inbox, Sent Items, Archive and own folders in the background once the Inbox is current, 50 messages per page, into encrypted history segments beside the mailbox cache. The download resumes after relaunch or an interrupted page, keeps new, moved, deleted and read mail current through each folder's delta link, and lists a folder again, keeping its earlier history counted, when Graph expires that link. The Microsoft Inbox state reports downloaded messages, the folders' total and whether the history is complete, so the Sync Status Capsule includes it; throttling pauses the download until the next synchronization.
- f1d4a0f: Keep validated link destinations in the Semantic Message Document through edits, Draft storage and Product Sync, and render them in outgoing HTML and plain text.
- 373fbc2: Underline linked Draft text and edit or remove a link's text and destination with the Link Editor on Mac, iPad and iPhone.
  Keep invalid pasted link labels out of the Draft so link edits remain saveable.
- c22af1b: Keep block alignment in the Semantic Message Document through edits, Draft storage and Product Sync, and render it in outgoing HTML.
- 05bf301: Keep text color in the Semantic Message Document through edits, Draft storage and Product Sync, and render it in outgoing HTML.
- 2cb0905: Keep background color in the Semantic Message Document through edits, Draft storage and Product Sync, and render it in outgoing HTML.
- d6ea20d: Keep font family and size in the Semantic Message Document through edits, Draft storage and Product Sync, and render them in outgoing HTML.
- 10ed643: Read Draft HTML from Gmail, Apple Mail, Outlook and outgoing mail into a Semantic Message Document, reporting what the document cannot hold. Outgoing mail keeps a code span's own font.
- fcec6f4: Add a link to selected unlinked Draft text with the Link Editor on Mac, iPad and iPhone, and name an invalid link destination after Return or on leaving the Link field.
- 13d15bf: Offer Rewrite, Translate and Suggest reply from one Writing tools menu in the iPhone and iPad composer.
- 9456102: Store a Mac composer's Draft only when the person chooses Save or sends it, as in
  Mail. Editing no longer saves or shows a save status. Closing an unchanged Draft
  closes at once and an empty one is removed; otherwise the window asks whether to
  save the message as a draft, and Don’t Save deletes it. Opening another Draft,
  New Message, received mail on compact layouts, Command-W, the window's close button
  and Quit ask the same question first.
  An open composer keeps its attachment and image bytes when another window deletes
  its Draft.
- ee99e36: Limit message link actions to 200 in rich, plain and fallback readers while
  preserving later text. Normalize repeated breaks, preformatted newlines and
  empty linked spacers so hidden suffixes cannot mask the visible link label.
  Remove unresolved sender CSS functions to bound large spacing around inspected
  link suffixes. Preserve ordinary RGB/HSL borders while bounding widths adjacent
  to their color functions.

  Preserve IPv6 host brackets and balanced URL-path delimiters when detecting
  plain-text links, while keeping surrounding sentence punctuation outside the link.

  Compare redirect hosts using normalized host keys so equivalent spellings do not
  produce a false cross-site caution. Offer rich-message link actions only for
  anchors with retained visible content, preserving the action limit for visible links.

  Recognize bare punycode domains in displayed link text so a different destination
  still produces a mismatch caution.

- ee99e36: Refuse Gmail messages nested more than 32 MIME levels deep or with more than
  10,000 parts instead of exhausting the stack while reading them. Inspect a
  link's painted text apart from admitted image descriptions, so an image's
  alt text cannot mask a mismatched address. Render a message's replacement
  presentation after an earlier rich view failed.
- ee99e36: Resolve CSS comments before image visibility checks while preserving strings, escapes and token boundaries, so hidden inline images are not downloaded and visible images remain available.
- ee99e36: Resolve repeated message styles by importance and supported value validity so
  hidden inline images are not fetched and valid visible overrides retain mail.
- ee99e36: Preserve message text when MIME headers contain charset decoys, and prevent
  inline-image downloads from hidden CSS escapes or internally spaced Content-IDs.
- b45a92b: Show unsaved Draft changes and a Save Drafts retry action in the Inbox when saving fails or private storage is locked. On iPhone, selecting the current Draft reveals its composer again. Compact native Back can still hide an unsaved composer; its transition protection remains required before release.

  Return no new Draft identifier when the Product Account changes before creation finishes.

- b45a92b: Keep each composer bound to its own conflicting Draft through continued typing,
  Undo, Redo, storage recovery and Discard. Preserve the newer stored version's
  identity, and group subject typing by words at the caret.
- b45a92b: Preserve To, Cc and Bcc roles in Draft list text and accessibility labels on iPhone, iPad and Mac, so a Bcc-only Draft no longer appears addressed To someone.
- b45a92b: Preserve another storage writer's completed Draft edit when a stale editor discards its earlier version.
- dfc1f46: Keep malformed inline-image preview replies unavailable instead of reporting a
  healthy Draft asset without image bytes. Native-only attachment verification
  continues to accept its empty success reply.
- dfc1f46: Refuse translations of Draft selections containing inline images with guidance to
  select text alone, preserving image references while translating surrounding text.
  Expose Mac summary and translation explanations as accessible native text.
- 1ccb9af: Keep Draft Discard and divergent edits safe across interrupted publication and updates,
  concurrent local stores and relaunch. Log failed automatic synchronization passes
  and distinguish deleted-record conflicts from transport failures.
  Automatic app lifecycle requests use the shared `syncInBackground` action;
  explicit `sync` callers continue to receive unexpected rejections.
  Mac windows share one Draft lifecycle subscription so each app transition starts
  one synchronization pass for their shared store.
- 0668ad3: Bound reader translation input while traversing paragraphs and spans, so opening a long message does not join its whole body. Keep an existing translation when only text beyond its captured prefix changes.
- ce247aa: Retry cache-only mailbox authorization before queued delivery after an offline launch, so reconnecting does not require switching apps or waiting for the Inbox poll. Keep a message waiting if verification rejects or leaves its mailbox cache-only, before claiming or handing it off and without blocking later Outbox entries. Defer unknown-message Sent checks after the same failed preparation without reporting a lookup that never happened, and allow a later check without resubmission.
- 5a4d34c: Recover queued Gmail and Graph sends after a native mailbox session renewal without requiring Inbox navigation.
- e3660b6: Add the Testing-only assistance-qualification build, which runs a versioned synthetic corpus through Apple's on-device model and Translation at launch and records its evidence. Production and every other build never run it.
- 77d3937: Treat a link the backend refuses, because the identity belongs to another
  Product Account or the sign-in is too old, as an expected outcome instead of
  logging it as an error. Encode the Inbox seed with its schema before sending it
  to native storage.

  Flush saved Private Inbox files and their directory to the drive with
  `F_FULLFSYNC`, falling back to `fsync` where the file system does not support
  it, before a change is reported as saved. Load the Mac Inbox once for all open
  windows, at launch and on each activation, instead of once per window.

  Stop compiling the test-only synthetic Keychain credential into both apps, and
  export the unencrypted mock Inbox storage only from mail-core's testing modules.

- 4ff7648: Run the registration flow in TypeScript over a minimal native vault. Restoring,
  signing in, switching to and linking sign-ins, verifying and adding Gmail
  mailboxes, and the order of sign-out and deletion now run as Effect programs in
  `@private-email/mail-core`, which decode every native result and Convex reply.
  Native code keeps the saved registration, provider sign-ins, the credential-issuing
  connect and the credentials every other Convex call carries; no device credential,
  provider token or Google subject crosses the bridge. iPhone, iPad and Mac behave as before.
- 452fec1: Run Product Sync initialization and mailbox descriptor synchronization in
  TypeScript. Deciding when to create and publish the account keys, reading every
  page of descriptors, compare-and-set writes, removals and their tombstones, and the
  Product Sync status shown on each device now run as Effect programs in
  `@private-email/mail-core`. Native code keeps every key: it creates and stores the
  key ring and Recovery Key before anything is published, and seals and opens each
  record. iPhone, iPad and Mac behave as before.
- ddb3700: Run device enrollment, Recovery Key recovery, key rotation adoption and Device
  Revocation coordination in TypeScript. Requesting and collecting approvals,
  approving and declining other devices, unlocking with the Recovery Key, adopting a
  removal's key epoch, and preparing, activating, settling and cancelling a removal
  now run as Effect programs in `@private-email/mail-core`. Native code keeps every
  key operation behind purpose-named steps that store keys, codes and proposals
  before anything is sent, and a Draft write refused for an earlier key epoch now
  adopts the newer epoch through the shared flow. iPhone, iPad and Mac behave as
  before.
- a7a53a6: Read Gmail sender names and addresses from positional captures, so Hermes builds show the display name even when a match carries no named groups.
- 01ed01c: Bound sender-controlled MIME metadata before any header is parsed: header count,
  total header text, header name and value length, Content-ID length and Gmail's
  MIME type. An explicit open of a message over a budget reports its body as
  failed, and prefetch keeps it on demand without pausing later prefetches. Find
  comment delimiters in one pass, so an unterminated quoted string no longer costs
  time quadratic in the header's length.
- e35b687: Keep typing, formatting and selection responsive in a single very long Draft paragraph by
  editing its runs of text instead of one object per character (#784).
- b4a3aae: Open Drafts with Inline Images and Attachments in the registration-draft-editor Tiptap evaluation editor, now laid out as the approved compose design: the current composer's header, sending mailbox, Subject, To, Cc and Bcc and Send around the page's body. iPhone formats from a floating Liquid Glass pill and a Format panel that replaces the keyboard, iPad and Mac keep the format bar, and Writing tools gather Rewrite, Translate and Suggest reply. Nothing is saved until Save Draft (Save on Mac) or Send; Close offers Delete Draft and Save Draft on iPhone and iPad, and the Mac asks whether to save. Images placed inline through the system pickers (and, on iPhone and iPad, Paste Image or a paste into the page) keep their Draft Asset identity through typing, moving, deletion, Undo, Redo, saving and reopening; a row's context menu turns an Inline Image into an Attachment or an image Attachment into an Inline Image as one undoable edit. The page receives only native thumbnails of verified bytes and refuses pasted or dropped files. Production and other scenarios retain the current composer.

  The draft-editor message API replaces `decodeUpdate` with `decodeMessage`, which also decodes the page's `paste` request; `update` messages carry the Draft's Attachments, the page accepts `add`, `remove`, `convert`, `previews`, `focus` and `editable` commands, and `knownAssets` keeps a reported body to the assets the host gave the page. `supported` is removed. Close, Save and Send wait for a read-only page acknowledgement so queued body edits are included; import settlement keeps the saved baseline current, and navigation resumes after Save or Delete.

  The Mac save question keeps background composer controls inactive and hidden from assistive technology, with keyboard focus retained in its choices until Save, Don’t Save or Cancel.

  Save and Send feedback, errors and assistance reviews scroll with the evaluation composer's content so they do not take space permanently from the body in a short window or above the keyboard.

  iPhone floating menus receive taps when they extend over the composer header in landscape.

  Queued toolbar and file actions leave the acknowledged page unchanged while Save or Send finishes, keeping the shown document consistent with the version being stored.

  Evaluation panels finish their closing animation while their controls become inactive immediately. Pending deletion follows the editor's conflicting copy after its window closes. Previously shown inline thumbnails are cleared when native revalidation finds the bytes unavailable.

  On Mac, closing a window with Command-W, its close button or Quit while the evaluation editor is open asks the same save question first instead of losing unsaved edits. Quit continues after each editor allows closing; Cancel or a failed finish keeps the app running.

- e34e9d2: Add the categorization-spike page to the iPhone and iPad build of that Mock Mail Session scenario, which runs the frozen DeBERTa candidates through Core ML on bundled samples. The Mac page now shares its session with it. Production and every other build keep the empty reader.
- 36780c7: Decode message bodies in legacy single-byte charsets, including Czech
  `windows-1250` and `iso-8859-2`, on iPhone, iPad and Mac instead of showing
  garbled UTF-8 text.
- d25bf63: Read inline message styles with the CSS Syntax tokenizer and parser from @csstools, so declarations split as WebKit splits them around curly blocks, bad URLs and stray closing brackets. A declaration nested more than 512 levels deep is removed before parsing instead of failing message preparation; other declarations still apply.
- 1225b7c: Make the native vault the only seam into Registration: `createRegistration` now
  takes the native vault and builds the registration flow itself, and the
  Promise-shaped native registration interface is removed. The registration Mock
  Mail Session scenarios become presets of the synthetic vault in
  `@private-email/mail-core/testing/registration-scenarios`, replacing the separate
  `testing/registration-session` fake, so tests run the real registration flow and
  Product Sync.
- 72a884f: Assemble each host's mail-core stores in `@private-email/mail-core/host`:
  `createHost` builds Registration, mailboxes, Drafts, the Outbox, wakes,
  freshness and remote content settings over a lazily looked-up native module, and
  owns Gmail request cancellation and the device-removed hooks both hosts wrote
  twice. Each host looks up `UnwiredRegistration` in one place and restores
  Registration and remote content settings once at app start instead of from every
  Registration gate mount; push wakes still start on every launch, including
  headless ones.
- 5e9492b: Keep Outbox status and unknown-delivery recovery in the mail-core Outbox store.
  Hosts read entries through `outbox.subscribe` and `outbox.getSnapshot`, whose
  entries carry the Check Again state (`idle`, `checking` or `unconfirmed`), and
  word them with `outboxCopy(t, entry, provider)`. Every Mac window now shows the
  same Check Again progress and answer; the Edit warning stays local to its window.
  A pending check no longer publishes its answer once the message leaves the Outbox,
  is sent again or belongs to another Product Account.
- 8b23735: Give the Registration gate one view model: `registrationScreen(t, state, choice)`
  in `@private-email/mail-core/registration` returns the gate's destination, copy,
  actions with their labels, the Product Account's identity and Sign-In Providers,
  Mailbox Connections and private sync state. It also normalizes the Inbox choice.
  Each host window stores the returned choice, so a choice invalidated by sign-out,
  another Product Account or new setup is forgotten and cannot return with an
  earlier snapshot. The individual copy and action helpers are now private to
  mail-core. Mail-core modules import the registration snapshot model from
  `registration-snapshot.ts` instead of the store.
- 648cce3: Native registration operations no longer reject with `busy` while another one
  is running. They queue behind the native operation gate, so a Registration
  created after a JavaScript reload waits for the previous runtime's pending
  operation instead of failing. Registration rejections carry only their code.
  `busy` is removed from the registration rejection codes and the native
  diagnostics allowlist.
- 2bd7060: A reader whose inline images waited for the shared display budget now shows them as soon
  as any Gmail or IMAP reader frees it, without reopening: closing a Gmail reader admits a
  waiting IMAP window, closing an IMAP window admits a waiting Gmail reader, and a Gmail
  reader of another message takes the budget a closing Gmail reader held. Readers that were
  not held back keep their presentation. Removing a Gmail message from the cached views or
  refreshing it to a smaller presentation or hiding Remote Message Content also returns its
  display budget to waiting inline images.
- b3e892d: Redesign message reading on Mac, iPad and iPhone to match the design (#902).

  - **Toolbar:** the reader's organizing and response actions are SF Symbol buttons in Liquid Glass groups. The Mac keeps a fixed toolbar above the reading pane: Archive, Move to Trash and Labels or Folders, then Reply, Reply All and Forward, then the remaining actions. iPad places Archive, Labels or Folders, the response actions and More in a fixed toolbar above the reading pane. iPhone floats Archive, Labels or Folders, Reply and More over the bottom of the reader beside a circular New Message button. Reply opens a glass-backed modal sheet offering Reply, Reply All and Forward. More lists the remaining actions in a panel.
  - **Reading pane:** the subject uses Reading Subject, Mac shows the sender and address on one line with the received time trailing, and the body stays at Reading Body. iPhone adds a header with a glass Back pill carrying the mailbox's cached unread count and the truncated subject, an "N Messages" row in the Thread view, and neutral monogram initials beside each message's sender. Thread messages use the same header.
  - **Saved mail:** replies remain available while provider checks are pending or offline. The organizing explanation appears as a quiet notice in scrollable reader content without covering the message or clipping it in the toolbar.
  - **Attachments and links:** received attachments are quiet-fill chips with a document symbol, name, size and actions. Link confirmations are centered modal glass alerts with a link or warning-shield symbol, the title "This link may not be what it seems" for suspicious links, and stacked Cancel, Copy link and Proceed choices. Mac uses a supported window-level overlay that dims the list and reading pane together, hides background accessibility, and retains the selected mailbox and message ownership checks.

- 8741a65: On iPhone, Folders in the reader opens a glass Move to… sheet for IMAP and Microsoft mail (#904). The sheet names the connection's provider and address, narrows its folders with a search field, and lists one row per folder. The message's current folder is checked and cannot be chosen again. Choosing a folder moves the message and closes the sheet. Gmail keeps its Labels panel, and iPad and Mac keep their folder panels.
- ac2c3e7: Add native context menus on Mac, iPad and iPhone (#905): long-press on iPhone and
  iPad, pointer secondary click on iPad, and right-click or Control-click on the Mac.

  - **Message rows:** Archive, Flag or Unflag, Mark as Read or Unread, and Delete,
    as the row's provider offers them, with Delete last on every platform.
  - **Open message:** the reader's header lists Reply, Reply All and Forward (side by
    side on iPhone and iPad), its read state and flag, Move Message with the reader's
    destinations, and Delete Message. The sender offers Copy Address.
  - **Links and attachments:** the reader's link list offers Open Link, through the
    usual confirmation, and Copy Link; a downloaded attachment offers Quick Look and
    Share….

- 583a0f9: Redesign Settings on the Mac, iPhone and iPad (#906). With a connected Inbox, the
  account page is now Settings: Account & Devices, Email Accounts, Language and
  Privacy & Data, in the design's grouped rows with section titles, footers, push
  buttons and a Mail Assistance switch. The Mac and iPad show a glass sidebar of
  destinations beside the selected one; iPhone lists them and pushes one at a time
  with a way back, opening on Account & Devices while setup waits there. Per-mailbox
  remote content choices now sit with the device policy in Privacy & Data, which
  also states that Known Tracking Pixels stay blocked. Only settings the clients
  support appear; the welcome flow keeps its layout. Removing another Trusted
  Device starts with a confirmation dialog and retains the required
  replacement Recovery Key confirmation afterward.
- a59ebbb: Drafts and Mail Assistance follow the Mail Profile that owns their connection. A Draft's
  Rewrite, Suggest reply and Translate use that Profile's consent, and a request is retired
  whenever the connection moves to another Profile. Settings offers one Mail Assistance
  switch per Profile; with only the Default Profile it is unchanged. Each window lists only
  its own Profile's Drafts and Outbox. Moving a connection keeps its Drafts, the queued
  message and its delivery claim.
- f7962f2: Approve the `registration-enrollment` Mock Mail Session from the synthetic TypeScript trusted device, which seals CryptoKit-compatible HPKE with pure JavaScript cryptography bundled only into Mock Mail Session builds. The Swift synthetic registration provider and backend are removed.
- 417d4f8: Keep wide HTML email readable on iPhone and iPad. Desktop-width tables and blocked
  remote image placeholders now narrow to the reader column instead of clipping text
  at its right edge, and content that still needs more room, such as unwrappable
  text, scrolls sideways inside the message. `decodeMessageContentHeight` is replaced
  by `decodeMessageContentSize`, which also returns the measured width.
- 5b0f682: Rich email bodies now follow the app's Light or Dark appearance on iPhone, iPad
  and Mac instead of showing a white canvas in Dark mode. The reader uses the
  shared content background, primary text and link colors, restyles an open
  message when the appearance changes, and still removes sender colors (#977).
- a0e94a2: Keep a list started with `- ` in the iPhone and iPad composer, and continue it on Return, when typing faster than the composer redraws.

  Keep word-sized Undo steps while native text is ahead of the display, and expose that typing classification with the semantic edit.

  Replace selected list markers only when they are included in the field's selection, whether or not its display has caught up.

- 1c6c663: Stop the composer's save status from blinking while you type. Successful saving
  on iPhone, iPad and Mac no longer shows **Saving…** or **Saved on this device**;
  the composer only says when an edit is not saved, because saving failed or
  private storage is locked, and keeps its existing recovery.
- b45a92b: Build Draft row previews from a bounded excerpt at the start of the body, avoiding
  full-body strings when the Inbox opens or a body edit refreshes its row.
- b45a92b: Bound Draft row metadata, composer titles and From previews before displaying or
  announcing them, identify shortened metadata in accessible names, and decide
  whether a Draft is empty without joining its whole body. Full authored content
  stays available for editing and saving.
- b45a92b: Keep the later edit time when concurrent storage writers save identical Draft
  content, preserving its position in the newest-first Draft list after reopening.
- dfc1f46: Show bounded Draft image thumbnails while keeping verified files without a decodable preview available.
- b45a92b: Keep typing responsive in long Drafts by rebuilding only the changed blocks, and
  refuse a Draft save whose encrypted file would exceed the 100 MB limit.
- b45a92b: Preserve same-account late Draft edits as conflict copies after deletion, keep
  edits accepted during a failed discard, and allow navigation to retry after an
  unexpected composer save failure.

  Leave unchanged editor content alone when another writer saves a newer Draft,
  without creating a stale conflict copy. Expose the shared composer navigation
  coordinator for both hosts.

- d4bc7ee: Fix Google and Apple sign-in linking rejecting fresh identities when Convex omits the reserved JWT issue-time claim. Validate freshness from the gateway-authenticated bearer token in HTTP actions, retain internal ownership transactions, and explain that the current provider is verified before the provider being linked. Rebuild the native hosts with the matching backend deployment.

  Load local host configuration for Mac native builds, use the active Ruby gem executables, and generate automatically signed Apple Development projects. Preserve Google SDK diagnostics in the private native log.

- a426f0a: Add installation-local, opt-in error reporting with safe exception details and bounded breadcrumbs, consent revocation, and verified remote deletion. Native crash collection remains disabled pending platform qualification.
- 262ac82: Keep registration and the mailbox usable when this device's Product Sync keys
  cannot be read. Restore, sign-in and Gmail authorization now report Product Sync
  as unavailable instead of failing and recording a mailbox failure, keep the
  unreadable keys unchanged, and log Product Sync errors by domain and code only.
- 30b173c: Keep body admission ordered with Gmail action commits so late downloads cannot restore cached bodies of messages removed during reconciliation.
- b45a92b: Start a New Message Draft only from a mailbox that can still send for the current
  Product Account once the open composer has finished saving.
- 982d813: Keep Mac Outbox delivery running independently of windows and pause new iPhone and iPad handoffs outside the foreground, preserving durable claims, Undo Send deadlines and uncertain outcomes.
- b45a92b: Discard the editor's own Draft after earlier autosaves finish, including when a
  conflict moves it to another copy. Keep repeated Undo and Redo commands advancing
  one step each before the composer redraws. The Draft store's discard action also
  accepts a target resolver for editors whose identity can change while saving.
- b45a92b: Keep another editor's completed Draft when a stale composer discards, while
  discarding the composer's own version even if a late text event arrives during
  saving. Preserve destinations chosen during slow New Message creation, retain
  the new Draft if its row is selected, and remove only abandoned empty Drafts,
  including at the next successful save when storage was locked.
- b45a92b: Recover a stale Draft discard after another storage writer saves, preserving
  completed content when an empty composer closes and settling its saving status.
  Apply body edits and typing marks at the latest caret even before the composer
  redraws. Hide the Drafts heading alongside its rows during received-mail search.
- 9612f48: Moves the Convex backend, the shared mail core and the iPhone, iPad and Mac apps from the Effect 4.0.0-rc.118 release candidate to the stable Effect 4.0.0 release. No user-visible behavior changes.
- b45a92b: Release a closed composer from the Draft store, so a window closed while saving
  fails no longer stays in memory or follows later conflict copies; its unsaved
  edits are still saved.
  A pending Close or Discard keeps following its own version until it finishes,
  including when its window closes during a conflicting save.
- e135c7c: Reload an already-open IMAP Inbox after its password is entered again, including
  when it is still current, without restarting the app. Registration subscribers
  receive the repaired connection ID only on a successful IMAP connection, so
  unrelated registration changes do not retry other refused mailboxes.
- 685494c: Share registration action and sign-in offer rules between the mobile and macOS hosts while preserving their existing behavior.
- a1bc55d: Show a locked state instead of onboarding when the app launches while the device
  is locked, and restore the saved account once the app becomes active after
  unlock. Restore also verifies unlocked accounts on every activation, preserving
  setup feedback when the restored status is unchanged. Only unavailable protected
  data is reported as locked; a missing Inbox
  key or another Keychain failure is reported as unavailable, since unlocking
  cannot recover it.
- e201a9a: Expose the mock registration relay adapter and synthetic Effect layers for packaged test journeys. Provider tokens and device credentials stay native, and synthetic backend changes become visible only after persistence succeeds.
- 611c8d3: Add isolated deterministic Mock Mail Session providers and native runners for the open, mark-read and encrypted relaunch journey. Keep scenario selection and cleanup outside the apps and exclude test providers from ordinary bundles.
- Updated dependencies [edac772]
- Updated dependencies [07d8147]
- Updated dependencies [3184c0f]
- Updated dependencies [b5bd44a]
- Updated dependencies [0c7e666]
- Updated dependencies [b9f0c48]
- Updated dependencies [a1c0ccb]
- Updated dependencies [ee887ce]
- Updated dependencies [4b9a4b8]
- Updated dependencies [98b2991]
- Updated dependencies [64aac67]
- Updated dependencies [860369c]
- Updated dependencies [4b314a8]
- Updated dependencies [f2d35d2]
- Updated dependencies [6bb7771]
- Updated dependencies [a35a049]
- Updated dependencies [2fba864]
- Updated dependencies [5e27303]
- Updated dependencies [dee8006]
- Updated dependencies [d65b96e]
- Updated dependencies [b7fc9a4]
- Updated dependencies [e122954]
- Updated dependencies [1c52450]
- Updated dependencies [3a6a227]
- Updated dependencies [85bbda1]
- Updated dependencies [a787e87]
- Updated dependencies [1a7cb66]
- Updated dependencies [52a62f7]
- Updated dependencies [fe54ada]
- Updated dependencies [d0de90a]
- Updated dependencies [f6bf0cb]
- Updated dependencies [1ccb9af]
- Updated dependencies [1ccb9af]
- Updated dependencies [506964e]
- Updated dependencies [8e745d8]
- Updated dependencies [0c85d0a]
- Updated dependencies [c70cb72]
- Updated dependencies [e135c7c]
- Updated dependencies [02bb862]
- Updated dependencies [ebcb577]
- Updated dependencies [a182684]
- Updated dependencies [e9230a2]
- Updated dependencies [e2db13e]
- Updated dependencies [043d25c]
- Updated dependencies [0548a1a]
- Updated dependencies [6ee2629]
- Updated dependencies [3f028f0]
- Updated dependencies [d802688]
- Updated dependencies [02178a0]
- Updated dependencies [b4a3aae]
- Updated dependencies [fab7a42]
- Updated dependencies [1438300]
- Updated dependencies [172b3cc]
- Updated dependencies [b3e892d]
- Updated dependencies [8741a65]
- Updated dependencies [ac2c3e7]
- Updated dependencies [583a0f9]
- Updated dependencies [1276608]
- Updated dependencies [cb69e6d]
- Updated dependencies [d6d8ffa]
- Updated dependencies [80b3de7]
- Updated dependencies [a59ebbb]
- Updated dependencies [3d62e75]
- Updated dependencies [43b0b57]
- Updated dependencies [76fd227]
- Updated dependencies [8d15586]
- Updated dependencies [da83d19]
- Updated dependencies [59aec8b]
- Updated dependencies [18ae953]
- Updated dependencies [754cb3d]
- Updated dependencies [4838390]
- Updated dependencies [a426f0a]
- Updated dependencies [80be581]
- Updated dependencies [88bbcdc]
- Updated dependencies [7c38123]
- Updated dependencies [2fed635]
- Updated dependencies [cd85233]
- Updated dependencies [7048de3]
- Updated dependencies [cb7297b]
- Updated dependencies [a8dd542]
- Updated dependencies [3d8b483]
- Updated dependencies [6f28fe0]
  - @private-email/localization@0.1.0
  - @private-email/contracts@0.1.0
