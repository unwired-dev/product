# @private-email/localization

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

- a182684: Connect and read Microsoft mail on iPhone, iPad and Mac. Product Sign-In with Google or Apple no longer starts Gmail consent on its own: **Connect your mail** offers **Authorize Gmail**, **Choose another Google mailbox** and **Connect Microsoft mail**, and the account page adds **Add a Microsoft mailbox**. Microsoft actions appear only when the build has a configured Microsoft client ID or a mock provider. A personal Outlook.com or work/school Microsoft 365 mailbox connects through Microsoft's sign-in with read-only mail access, without any Gmail grant, and its Inbox joins the unified Inbox through Microsoft Graph: the newest 200 messages first, then delta changes, with bodies, inline images and attachments read on demand into the same encrypted caches. Cancelled or refused consent, tenant restrictions, an account without an Outlook mailbox, expired delta state and a refused grant each keep the Product Account and show a state to retry or authorize again. A grant refused while reading attachment metadata still asks for authorization when the message also exceeds the MIME metadata budget. Organizing, online search and sending stay Gmail-only for now.

  Microsoft messages without a usable conversation ID stay separate in the Thread view; messages sharing a conversation appear newest first. Malformed native capability replies keep Microsoft authorization unavailable without failing setup.

- 043d25c: Prepare both native clients for translated interface text. All interface copy, including registration, private sync, search, organizing, the reader, attachments and the Draft composer, now comes from one shared English catalog with per-key English fallback. The Language control under the Inbox and on the account page offers System default or a saved, device-local override. Dates and file sizes follow the device's regional format, including its calendar, numbering system and 12/24-hour preference, and Mac menus and window titles use the same catalog before JavaScript starts.
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

- 76fd227: Redesign search on iPhone and iPad: focusing the search field opens a search mode with Close Search beside the field, results under Top Results with the query's words in bold in each sender and subject, and, in a single mailbox or folder, an All Mailboxes / Current Mailbox choice. Editing or clearing the query keeps search open instead of flashing back to the Inbox. A new Filter button narrows the Inbox to unread mail, mail from today or chosen mailboxes through the Filters sheet, and shows what the Inbox is filtered by. Filters opens as a full-height sheet on iPhone and as a popover above the Filter control in a regular-width iPad window, where the floating bar spans the whole window with a centered 400pt search field. The theme adds the 18pt `radius.popover` token. `matchedRanges` in `mail-core` finds where a query's words appear in a field, matched as search matches them. The shared `filterMessages` projection applies the host's `InboxFilter` settings to validated listed metadata.

  While iPhone search replaces the heading, a downward swipe on its field opens the Command Palette. The field keeps its palette entry methods if private storage locks during search.

### Patch Changes

- b5bd44a: Load Remote Message Content in IMAP mail on iPhone, iPad and Mac. The IMAP reader now
  follows the device's remote content policy and the connection's own setting, which
  Settings offers for IMAP mailboxes too, with the same **Load images** consent,
  Authorized Remote Content Cache, tracking-pixel blocking and shared display budget as
  Gmail mail. `createImapInbox` accepts its `connection` and exposes `loadRemoteImages`
  and `forgetRemoteImages`; `NativeImapMailbox` includes the remote content cache calls,
  and the controlled `testing/imap-mailbox` fixture serves remote images. The reader's
  "not loaded yet" notice for IMAP mail is removed.
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
- 6ee2629: Removing a Trusted Device now seals the new key epoch separately to each remaining Trusted Device's own encryption key and to a replacement Recovery Key. Nothing the removed device held opens it, not its keys, earlier rings, enrollment secrets or earlier Recovery Keys. Each device binds a long-lived encryption key when it creates the account's keys, confirms admission or first unlocks with the Recovery Key. A bound key is never replaced, and a device that loses its key enrolls again as a new device.

  On iPhone, iPad and Mac, **Remove** now shows the replacement Recovery Key first and asks for its last four characters. Cancelling changes nothing. Confirming removes the device, activates the new epoch and makes the replacement Recovery Key current, all at once, after a recent sign-in. If the account changed meanwhile, a fresh key is shown to save and confirm again. A lost reply keeps the proposal on screen, and confirming again never removes twice.

  Remaining devices no longer have to adopt a removal before it completes. A device that was offline adopts the newest keys directly when it reconnects, without the Recovery Key. Writes sealed at an earlier epoch are refused and sealed again after adopting the new one. The previous Recovery Key stops admitting devices as soon as a removal activates.

  Losing a device encryption key preserves an unconfirmed Recovery Key or unanswered removal until it is settled. Ordinary private sync and enrollment decisions remain unavailable until the installation enrolls again.

- 02178a0: Extend the registration-draft-editor Tiptap evaluation editor to formatted Drafts: headings, lists, quotes, code and inline marks with Markdown shortcuts, word-step Undo and Redo, an explicit paste policy, and reviewed rewrites, reply suggestions and translations applied as one page edit. Production and other scenarios retain the current composer.

  Return continues bulleted and numbered lists and quotes even on an empty item or line.

  The draft-editor message API replaces `decodeChange` and `change` messages with `decodeUpdate` and revisioned `update` messages carrying selection and formatting state.

- b4a3aae: Open Drafts with Inline Images and Attachments in the registration-draft-editor Tiptap evaluation editor, now laid out as the approved compose design: the current composer's header, sending mailbox, Subject, To, Cc and Bcc and Send around the page's body. iPhone formats from a floating Liquid Glass pill and a Format panel that replaces the keyboard, iPad and Mac keep the format bar, and Writing tools gather Rewrite, Translate and Suggest reply. Nothing is saved until Save Draft (Save on Mac) or Send; Close offers Delete Draft and Save Draft on iPhone and iPad, and the Mac asks whether to save. Images placed inline through the system pickers (and, on iPhone and iPad, Paste Image or a paste into the page) keep their Draft Asset identity through typing, moving, deletion, Undo, Redo, saving and reopening; a row's context menu turns an Inline Image into an Attachment or an image Attachment into an Inline Image as one undoable edit. The page receives only native thumbnails of verified bytes and refuses pasted or dropped files. Production and other scenarios retain the current composer.

  The draft-editor message API replaces `decodeUpdate` with `decodeMessage`, which also decodes the page's `paste` request; `update` messages carry the Draft's Attachments, the page accepts `add`, `remove`, `convert`, `previews`, `focus` and `editable` commands, and `knownAssets` keeps a reported body to the assets the host gave the page. `supported` is removed. Close, Save and Send wait for a read-only page acknowledgement so queued body edits are included; import settlement keeps the saved baseline current, and navigation resumes after Save or Delete.

  The Mac save question keeps background composer controls inactive and hidden from assistive technology, with keyboard focus retained in its choices until Save, Don’t Save or Cancel.

  Save and Send feedback, errors and assistance reviews scroll with the evaluation composer's content so they do not take space permanently from the body in a short window or above the keyboard.

  iPhone floating menus receive taps when they extend over the composer header in landscape.

  Queued toolbar and file actions leave the acknowledged page unchanged while Save or Send finishes, keeping the shown document consistent with the version being stored.

  Evaluation panels finish their closing animation while their controls become inactive immediately. Pending deletion follows the editor's conflicting copy after its window closes. Previously shown inline thumbnails are cleared when native revalidation finds the bytes unavailable.

  On Mac, closing a window with Command-W, its close button or Quit while the evaluation editor is open asks the same save question first instead of losing unsaved edits. Quit continues after each editor allows closing; Cancel or a failed finish keeps the app running.

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
- d6d8ffa: Settings no longer replaces the Inbox. On the Mac it is one independent window, opened from
  the app menu's Settings… (Command-,), the Account button, the Command Palette or an IMAP
  password repair; opening it again brings that window forward on the destination asked
  for. iPhone pushes Settings onto a native stack with edge-back, while iPad opens its
  two-column workspace over the kept Inbox; Open Inbox also returns. Opening Settings no longer closes an open composer, so Drafts,
  mailboxes and selected messages are kept, and Settings closes when no Inbox can open.
- a59ebbb: Drafts and Mail Assistance follow the Mail Profile that owns their connection. A Draft's
  Rewrite, Suggest reply and Translate use that Profile's consent, and a request is retired
  whenever the connection moves to another Profile. Settings offers one Mail Assistance
  switch per Profile; with only the Default Profile it is unchanged. Each window lists only
  its own Profile's Drafts and Outbox. Moving a connection keeps its Drafts, the queued
  message and its delivery claim.
- 43b0b57: On iPhone, Reply in the reader grows a floating glass sheet out of the button (#969). It shows the sender's initials, name and message preview beside a Close button, then Reply, Reply All, Forward and Archive tiles and the Thread's other organizing actions in grouped rows, beside the toolbar's More, and shrinks back toward the button when closed. Reader menu panels and the composer's pop-up menus now ease in from their control and fade out on iPhone, iPad and Mac, and Folders on iPhone opens a Move picker that grows out of the button the same way: the mailbox's address, the message's sender and subject, folders with their role symbols (the current one unavailable) and a search field at the bottom. With Reduce Motion, menus and sheets only fade.

  Move search keeps its results visible in landscape with the software keyboard open.

- 3d8b483: Add a locally packaged plain-paragraph Tiptap Draft editor for the isolated registration-draft-editor evaluation scenario, saving through the existing Draft store. Production and other scenarios retain the current composer.
