# @private-email/mobile

## 0.3.0

### Minor Changes

- 9f70616: iPhone and iPad offer each unsaved message the previous run kept (#2379, part of #1989).

  - Once the Drafts open after a relaunch, and while no composer is open, the app asks **Recover unsaved message?** in a system alert for each composer recovery record the previous run left in the shown Mail Profile. **Restore** opens the composer on the recovered version, which Close then asks to save; **Discard** removes the record unless a composer has the Draft open, and keeps the stored Draft as it was. Records this run writes are never offered.

- 9054e1a: iPhone and iPad disable Send while the Draft cannot be sent as it is, and say why before Send is pressed (#2396, part of #2092).

  - **Add a recipient to send.** shows under To, or on one line above a docked iPad reply's From and Send; text that is not an address says it is not a complete address once its field is left. VoiceOver reads the reason with Send.
  - A sending mailbox that needs sign-in again shows the Authorization Needed banner under From, with **Sign In…**; the Sent folder, file and other sender problems show among the composer's notices.

- 0f25336: Each Trusted Device reports its kind and when it was last active in an end-to-end encrypted
  Trusted Device Record (ADR 0079). The Trusted Devices list in the registration snapshot includes
  the device in hand, marked `current`, and gives each device its reported `kind` and `activeAt`.
  On iPhone and iPad, Account & Devices lists every Trusted Device with its kind's symbol, its name
  and "This iPhone" or "This iPad" with Current Device, "Last active …" with the exact time, or
  "Added …" with a neutral symbol until the device reports. VoiceOver reads each row as one element
  with Remove as its action. The Mac still lists only the devices it can remove (#2607).
- ed3e5d8: On iPhone and iPad, Message Zoom… in the reader's More menu zooms the open formatted message alone until it closes, and Use … for All Messages keeps the level as Settings › Reading's Message Zoom (#2806).
- 82e8d34: On iPhone and iPad, the reader's sender menu offers Block Domain… under Block Sender…: its sheet blocks the sender's exact domain, with its subdomains or alone, and can exempt the person's contacts there. Settings › Blocked Senders lists each Mail Profile's Domains before its Addresses, shows an `xn--` domain with the characters it displays, and unblocks a domain by swipe or Edit. Mail core adds `offeredDomain`, `parentDomain`, `addressesAtDomain` and `shownDomain`.
- 70e2779: Settings › Reading on iPhone, iPad and Mac offers **Mark as Read** for each Mail Profile: **Immediately** (the default), **After 2 seconds** or **Manually**. The reader marks Gmail, Microsoft and IMAP mail read on opening as the Profile chose, and the choice syncs to the Profile's other devices (#2829).
- 432b580: On iPhone and iPad, the body's @ also works in written text, where choosing a person replaces only the query with their given name, else display name, else address, and it lists people already in To, Cc or Bcc with their role at the row's trailing edge, keeping that role and never adding them twice. On the Mac, iPhone and iPad, people already on the Draft always follow the other recent people, once each, under their newest name from their mail, else the Draft's, and match either name. `@private-email/mail-core` drops `bodyRecipientSuggestions`, which `bodySuggestionSections` replaced (#3108).

### Patch Changes

- 9d395a4: Preview Inbox builds read a fixed clock from the `-UnwiredNow` launch argument, so the visual report captures the same times and dividers on every run (#1061).
- 8101627: SwiftMail moves to release 1.18.0. An IMAP search whose server completes without
  reporting its matches now fails and can be retried, instead of reading as no
  matches. Closing an IMAP session no longer waits for a command still in flight:
  the command is cancelled and its connection closes. A server that refuses the
  listing of another user's or a shared namespace no longer fails the folder list;
  the mail cached under that namespace stays, for now even after its folders are
  removed, while only listed folders appear and serve as Sent or Drafts. When the wait for new mail ends,
  events the server sends before it acknowledges the end still reach the wait.
- 282b41c: Cancelling an IMAP attachment download, or closing a message's last reader while
  one downloads, now ends the mail server's transfer of the message source instead
  of letting it finish in the background, so a new download can start sooner.
- 63d5dcc: IMAP reads of message lists, flags and header fields now stop as soon as a mail
  server sends more replies than the messages they asked for, or header fields
  larger than their budget, instead of keeping everything the server sends.
- f6bdbd4: When Gmail has expired a mailbox's history, the next synchronization asks Gmail again for each online search result and Show Latest message the app holds, and drops those Gmail deleted meanwhile: a search no longer lists a deleted message, and an older invitation stops offering **Show Latest** for a deleted newer revision. Results Gmail still has, and their open reader, stay (#1859).
- d5b1d4c: iPad Command Palette: the esc key cap that closes it takes a 44pt touch target at every text size, so it passes the hit-area audit (#1873).
- f85260d: Composer: the header title, which offers **Open Command Palette** to VoiceOver, is a 44pt accessibility element, so it passes the hit-area audit on iPad (#1873).
- 9eb341e: iPhone Mailboxes shows a Mailbox Connection's problem as a warning triangle beside its
  header, which VoiceOver reads with the header, and the connection's Inbox row keeps its unread
  count. While the connection needs sign-in again, a banner above its folders says so and offers
  Sign In…, or Enter the Password… for an IMAP account (#2099).
- ce04f2c: Message dates follow the device's time zone instead of UTC. The reader's header on Mac and iPad
  says `Today, 8:12`, `Yesterday, 8:12`, `Sun 11 Oct, 21:14`, or the date with its year, in the
  interface language's conventions; iPhone's compact header names the day as its list row does.
  VoiceOver reads the full date and time. Message rows, the list's day dividers and Only Mail from
  Today use the same day, which changes at local midnight and with the device's time zone. The
  native language settings now report `timeZone`, and `messageDateSections` and `filterMessages`
  take it. A response still quotes a full UTC date for a message without a Date header (#2102).
- 21f5b6a: On iPhone the message body fills the composer, with attachments at its bottom, and Subject, To and Cc follow it below the fold (#2119). Send while it waits for a recipient scrolls to the fields and focuses To, or the field whose text it refuses, with its reason.
- 22026ed: In a compact iPad window the reader shows the Command input in its navigation bar, beside Back
  with the mailbox's unread count, and the composer sheet ends its From row with the input as the
  command symbol alone (#2133).
  Composer navigation counts the leaves it allowed, so a command waiting on a closing composer can
  tell when another destination was chosen.
- 2e994bd: The iPhone and iPad Remind Me to Send choices name the time zone in full on device, as in "Times in
  Central European Standard Time (Prague)", instead of only "Central": Hermes on Apple splits
  `formatToParts` at each space, so the line now takes the name from the formatted date. The iPad
  popover takes its frame's width, so the line stays on one line (#2147).
- 6a38208: iPad at the accessibility text sizes: Mailboxes hides in Portrait and Landscape, so the list and the reader keep their words whole, and **Show Sidebar** shows Mailboxes in the list's place beside the reader. Choosing a Mailbox shows its list again (#2193).
- 0f3fba1: **More from Mail Servers** no longer drops another mailbox's failed search. A
  mailbox whose first page failed keeps its reason and **Try Again** until it is
  searched again, so the online results no longer read as **No Results** when that
  mailbox was never searched.
- fd50bbb: Searching a Unified Mailbox such as Sent now settles on its results on the Mac, iPad and
  iPhone. Before, the list was rebuilt on every render, so the search asked again which results
  had saved bodies and never stopped re-rendering (#2355).
- e015cfb: A composer whose Draft update the store declines, as when its sender moved into another Mail Profile, no longer counts that version as saved: Save keeps the composer open and its recovery record stays. On the Mac, an idle Inbox window offers a recovery record once a mailbox moves into its Profile (#2373, part of #1989).
- e74502a: Composer recovery waits for a pending New Message and tries a refused record removal again (#2381, part of #1989).

  - iPhone and iPad no longer ask **Recover unsaved message?** while a new Draft is being created, so **Restore** cannot open a composer that the new message then replaces. The record is offered once that composer closes.
  - On iPhone, iPad and Mac, an open composer keeps a recovery record it could not remove and removes it with the next write. A removal that finishes after newer edits were journaled leaves their record in place.

- 92f1de1: The iPhone composer uses the iOS text styles: Compose Fields are 44pt rows of Body 17/22 under a 1pt rule, recipient tokens show their name in Body, the From pop-up is a 34pt capsule of Subheadline, Attachment Chips space their parts 10pt apart, and the On device marker is Caption 1 Emphasized (#2384, part of #2088).
- ec16f71: Connecting an Outlook.com mailbox no longer stops at **Mailbox access was interrupted** after consent: the app accepts the authorization callback Microsoft returns with a trailing slash (#2389).
- 6d7c277: The iPhone and iPad reader show a body that is still loading and one that cannot be shown as their frames draw them: on iPad **Downloading from Gmail…** above still placeholder lines, on iPhone a centred **Loading message…**, and on both a **Couldn’t load this message** banner with the reason and **Try Again** (#2395, part of #2091).
- ae9692a: IMAP mailboxes find a message's Sent copy by its Message-ID instead of a Content-Type search, so Seznam Email, whose server drops the connection on that search, files Sent copies and **Check Again** can confirm a message whose delivery was unknown (#2402).
- 2c8dd33: On iPad a docked reply stops growing at 720pt, so in Portrait it is 442×720 across the reader as the Portrait Compose Inline frame draws it; Landscape keeps two thirds of the window.
- ec47cb4: On iPad, rotating to Landscape and back returns Portrait to its default and hides Mailboxes again, keeping the list at the window's edge beside the reader; before, a rotation could leave Mailboxes shown, narrowing the list (#2414, part of #2095).
- e6be4e9: iPhone Mock Mail Session builds offer the German test catalog as **Deutsch**, as Mac ones do; shipped builds never carry it. A recipient field's placeholder that does not fit beside Cc/Bcc now ends with an ellipsis instead of clipping (#2415, part of #2096).
- 98f27cb: iPhone says a Trusted Device removal in two sentences: “{name} loses access to your Unwired account and sync, and you save a new Recovery Key. Mail it already holds can’t be erased remotely.” iPad and Mac keep the full explanation (#2416, part of #2100).
- 592c536: The iPhone Command Palette hint at the top of the Inbox list is drawn as the approved frames show: a quiet card with a 10pt radius and no shadow, and a 44pt round Dismiss. VoiceOver reads its title and detail as one element, then Dismiss (#2418, part of #2100).
- e1948d0: On iPhone and iPad, Settings › Blocked Senders that this device couldn’t read says **Couldn’t Load Blocked Senders** in the middle of the page, as the approved frames draw it, and **Try Again** reads them again; before, the page asked to leave it and open it again (#2420, part of #2100).
- 31951ed: iPad All Inboxes: the subtitle under the heading shows only the unread count and sync status, as drawn, instead of repeating "All Inboxes" (#2424, part of #2096).
- cba213b: On iPhone and iPad, a search that matches nothing shows the **No Results** state: centred on iPhone with its icon tile above "No mail saved on this device matches “…”", and at the top of iPad's list naming the scope and the query. While the mail servers are searched, an activity indicator stands above "Searching All Inboxes…" on iPhone, naming the shown scope, and above the mailboxes searched on iPad, as in "Searching All Mailboxes…". No Results waits until the list has listed and the mail servers have answered completely (#2435, part of #2090).
- 5246109: On iPhone and iPad, **New Label…** after a Gmail message's labels opens **Labels**: type a name, and **Create “Acme” inside “Clients”** creates the nested label in Gmail and applies it, while a name a label already has applies that label. A name another label has in a different case offers **Use “clients/acme”** or **Edit Name** instead of creating a duplicate (#2441, part of #1683).
- 1872d39: On the Mac, **New Label…** in a Gmail message's **Labels** menu opens the **Labels** popover in place of the name alert: type a name, and **Create “Acme” inside “Clients”** creates the nested label in Gmail and applies it, a listed label applies at once, and a name another label has in a different case offers **Use “clients/acme”** or **Edit Name** in a sheet. iPhone, iPad and Mac share the naming rules through `typedLabel` in `@private-email/mail-core/gmail-actions` (#2442, part of #1683).
- 4698039: An open online search stops listing a message once its provider confirms it deleted (Gmail's history or its expired-history check, or an IMAP change made on this device that moves it out of its folder or finds it no longer on the server), without searching again. The other results keep their order and their next page. IMAP Inbox snapshots now carry their held search results as `found`, as Gmail's do (#2451).
- dbb1218: An IMAP mailbox's open Sent folder now shows the copy the app just filed there, without a
  pull-down to refresh: once filing succeeds, the Sent folder saved on this device is read again
  before the message leaves the Outbox (#2454).
- 3b19eb2: On iPhone and iPad, the Send menu (a long press on Send) offers **Send Now**, "No Undo": it sends through the same Outbox checks as Send but without the Undo Send Window, with no confirmation. While a file is still being added, Send Now is dimmed and says "Waiting for <file> to finish". The Outbox's `send` takes a third `delay` argument, the Undo Send Window in milliseconds, which Send Now sets to 0 (#2457, part of #1674).
- 21d2d85: On iPhone and iPad, an invitation in an IMAP mailbox that can send offers **Accept**, **Maybe** and **Decline**: the response waits in the Outbox for the Undo Send Window with **Undo** and **View in Outbox**, then goes through the mailbox's own mail server, and the card names that server when it accepts, refuses or doesn't confirm the response. **View in Outbox** ends a search and shows the Outbox at the top of the message list. The Outbox shows the response in its own row with its meeting, choice and status, **Undo**, **Check Again** and **Open Invitation**, and no Edit (#2460, part of #1279).
- 44a7672: On Mac, iPhone and iPad, when storage refuses Undo for a waiting IMAP invitation response, the invitation card says **Couldn’t undo your response** and the Outbox row says _Couldn’t undo. Still waiting to send._, each with an amber warning triangle and **Try Again** in place of **Undo**. The notice clears once the response stops waiting (#2462).
- 0afa87f: When an IMAP mailbox's mail server refuses the password for an invitation
  response, the invitation card offers **Mailbox Settings…** below Accept, Maybe and
  Decline. It opens Settings at the mailboxes, scrolled to that mailbox's password entry
  (#2463).
- c416829: On iPhone and iPad, **Outdent** and **Indent** follow the list buttons in the Format panel and the format bar, and a hardware keyboard's Tab and Shift-Tab do the same inside a list. Lists nest three levels deep, each change is one Undo step, and sent mail nests the lists. The Semantic Message Document's list blocks gain an optional `indent` (1 or 2), `listIndentAt` and `indentList` change it, and `listNumbersOf` counts numbered items per level (#2465, part of #1679).
- 61a81c1: iPhone and iPad: Send and Send Now with files that were not added ask “Send without 2 attachments?”, naming each file and why, then remove them and send the rest.
- 17eb728: On iPhone and iPad a downloaded attachment's context menu is titled with its file name and offers **Save to Files…**, which saves a copy through the system document picker. The reader then shows a toast naming the folder and the copy's file name, with **Show** to open it in Files; cancelling says nothing, and when nothing was saved the reader says so and offers **Save to Files…** again (#2469, part of #1681). The inbox store's `saveAttachmentCopy` resolves the saved copy, `'cancelled'` or `'failed'`.
- 72aec6f: On iPad, the Filters popover opened in Portrait lines its leading edge up with the "Filtered by" control again after rotating to Landscape shows the sidebar, and centres on the control again after rotating back; before, it kept the placement it opened with (#2472).
- 005823d: On iPhone and iPad, **Settings › Notifications** offers an **App Icon Badge** pop-up with **Off** and **Unread in Inbox**. It starts **Off** and stays on this device. With **Unread in Inbox**, the app icon shows how many unread messages this device lists in the Inbox of every open mailbox, updated as mail arrives, is read or is archived, also during background synchronization, and cleared when the choice is **Off**, notifications are turned off, the last mailbox is removed or the person signs out. Asking for notification permission now includes the badge; while notifications are off, the choice stays, dimmed (#2478, part of #1723).
- de5f548: On iPhone and iPad, Settings has a **Reading** page under a new Mail group. **Message Zoom** (100% by default) zooms each received formatted message as you read it. The choice stays on this device; app text keeps following the system Text Size, and the message and your Drafts don't change (#2483, part of #1728).
- 191b6d3: Reader: VoiceOver reads the header's sender details as one element with **Copy Address** and **Block Sender…**, which in iPad's two-line header is large enough to press (#2484).
- f93b580: iPad: the Sync Status Capsule fits a list narrower than itself, as beside the sidebar in portrait, wrapping its message instead of being clipped, and its buttons keep their 44pt targets (#2484).
- 345644a: On iPhone and iPad, Settings › Reading has **Fit Wide Messages to the Screen**, on by default and kept on this device. A received formatted message wider than the reader now shrinks to the reader's width at every Message Zoom instead of scrolling sideways; turned off, it scrolls sideways as before (#2485, part of #1728).
- 21ef44a: Gmail's usage limit (a 429, or a 403 for a daily or rate limit) now pauses a Gmail Inbox's synchronization instead of retrying at once: until the time Gmail named, or after a wait that grows with each limit in a row, keeping saved mail and changes made meanwhile. The Gmail Inbox state reports the pause as `limit`, with Gmail's time and the day's count. On iPhone and iPad the Sync Status capsule says **Gmail paused** with that time, and the connection's details keep **Try Again** unavailable until it (#2488).
- 9a7cf95: iPhone, iPad and Mac composers share one composer recovery journal from mail-core (#2492).

  - mail-core adds the `recovery-journal` entry point: `createRecoveryJournal` keeps an open composer's unsaved version in its recovery record two seconds after an edit and on return to the foreground, through an Effect-managed wait that disposing the composer cancels.
  - Recording, removal retries and Mac Quit waiting for removal behave as before.

- 41140eb: Gmail's usage limit on the grant verification that activation and refresh run (a 403 for a daily or rate limit, like a 429) now keeps the saved Inbox open from its cache instead of asking to authorize Gmail again. A usage limit's automatic resume first verifies that connection again, as a push wake does, so a connection whose verification met the limit synchronizes at Gmail's time; `createInboxStore` takes that verification as its `verify` option (#2502).
- 7f14b01: A Gmail push wake now verifies only the mailbox it synchronizes with its provider. It still checks the Product Account and this Trusted Device, but no longer refreshes every other connection's grant or logs into every IMAP server within the wake's 25 seconds. After a wake that launched the app, the other mailboxes open their saved Inbox until the next activation or background refresh verifies them; in a running app they keep the access they had (#2506).
- 08f38d8: On iPhone and iPad, while the Inbox's search field has focus, one tap on **Search Mail
  Servers** now starts the server search and one tap on a result opens it, instead of the first
  tap only ending editing. Opening a message ends search editing, so the keyboard does not stay
  over the reader (#2549).
- 768201e: On iPhone and iPad, touching and holding an inline image's row in the composer offers Small (320 px), Medium (640 px), Large (1024 px) and Original, with a checkmark at the current size, then Remove Image; VoiceOver offers the sizes as actions. A size applies to every use of the image in the body as one Undo step. mail-core adds `imageWidthOf` and `withImageWidth` (#2577, part of #1735).
- abd9eec: On iPhone and iPad the Outbox is a row after Sent, in Mailboxes on iPhone and in the sidebar on iPad, while the Mail Profile has a message in it, instead of rows at the top of the Inbox column. Selecting it, or View in Outbox, ends a search and lists the messages under the heading Outbox with a subtitle counting those waiting and those not sent; when the last one leaves, the list returns to All Inboxes. VoiceOver hears where each message stands whichever list shows (#2589, part of #2101).
- f7ca447: On iPhone and iPad, toasts are Liquid Glass capsules instead of deep graphite: 48pt tall with a 24pt radius, the symbol and message in the primary text color and the action in the accent ink in Light. On iPhone a message that does not fit one line wraps to a 64pt toast. The refused Undo or Edit toast shows the frames' shorter "Couldn’t return the message to Drafts." (on iPad with the subject); VoiceOver still hears the full sentence (#2591, part of #2104).
- a1e183e: **Forward** and **Attach to New Message** download again an attachment saved before the mailbox's access was renewed, as happens on every Mac activation, and attach the received file. Forward marked it "Not added" and Attach did nothing (#2604, part of #632).
- 97c347a: On iPhone the composer is the system sheet over the mail it was started from. Swiping the sheet down is the same as **Close**: an unchanged Draft closes, an empty one is removed, and changed content asks **Delete Draft** or **Save Draft** first while the sheet stays open. The sheet's downward swipe belongs to the system, so the composer no longer opens the Command Palette on iPhone, as the app's other sheets do not (#2610).

  On iPhone and iPad, **Delete Draft** and **Save Draft** open over **Close** and visibly grow out of it, from a fifth of their size, as a system menu opens over its button; a tap outside them keeps editing (#2610).

  On iPhone the composer header matches the Compose frame: Send sits 16pt from the edge rather than 24pt, the title is centred, and in the sheet From sits directly under the header (#2610).

- 811634a: On iPhone and iPad, **Edit** in Mailboxes, beside Account on iPhone and the sidebar toggle on iPad, lets Favorites show or hide each row and reorder them until **Done**; All Inboxes stays shown. The rows are the Profile's synchronized Inbox preference the Mac already edits, hiding the selected Unified Mailbox selects the first row still shown, and the Command Palette opens each Unified Mailbox, leaving a reader or composer that covers the list first, and, while the iPad sidebar shows, Edit Favorites (#2611, part of #2106). Edit also shows or hides each Mailbox Connection and its folders and reorders them: connections in the Profile's shared order, where a refused order says so, and each connection's visibility and folders in synchronized Inbox preference fields of their own (`showSection`, `changeFolders` and `sections`, which is undefined until read and after a failed read; `sectionShown`, `sectionFolders`, `folderRows`, `showFolder`, `moveFolder`, and `showFavorite`, so a tap stores the opposite of what its row showed even when another write lands first and leaves every other folder in its stored place, even one this device has yet to list, and a tap that changes nothing stored, as on a connection's Inbox or on All Inboxes, which stay shown, writes nothing, so another device's newer choice stands). A hidden connection leaves All Inboxes and its search, and posts no New Mail Notifications on any device, the Mac included, as each delivery pulls the preferences from Private Sync once the notification settings are read, then checks the Profile its connection is in in the same step that hands them to the host (`arrived` takes `settle` and `eligible(profile)`), so a hide or move counts for every delivery checked after this device stores it, and none posts while that pull fails, the Profile's record does not open, or another device's write overtakes every pass (`pulled`); until the preferences are read, and while a later read fails, none posts, even one already pending. Hiding the selected connection or folder selects All Inboxes. A drag scrolls Mailboxes near its edges once the row moves, and changes nothing when another device reorders the rows meanwhile: `arrangeMailboxes` takes the order it was made `from` and writes nothing when the stored order differs, and an arrangement made during foreground verification is stored once it finishes; a Favorites or folder move onto rows whose order this device stored after showing them writes nothing either, as a `changeFavorites` or `changeFolders` change that returns undefined writes nothing. After a relaunch, All Inboxes lists no account's mail, nor Mailboxes any account, and Edit, from its button or the Command Palette, is unavailable, until the preferences are read, and All Inboxes names no hidden account, not even one waiting for or needing sign-in, nor counts one in its Sync Status Capsule, its subtitle, Filters, loading state, search progress or answer, or pull to refresh, and an account's own Inbox is named as its scope; All Inboxes takes its loading state, readiness and row motion only from the accounts it shows, none of them hidden, so a row leaving as an account is hidden leaves at once; while the preferences are read it shows it is loading, and after a failed read (`unreadable`, for each account whose read failed) it says so with Try Again, which, like pull to refresh, reads them again, a pull while they are read or unreadable then synchronizing the accounts they show; with every account hidden, even one waiting for sign-in, it names itself, not the provider, and shows No Mail and search answers once the preferences are read, without waiting for any account to list; a drag whose account another device removes ends with it; search widened from a connection's Inbox to every Inbox answers once the preferences are read, which a pull there reads again; signed out, `sections` hides none. `sidebarCommands` takes `unified` as optional, as it takes `favorites`.
- 6a9034c: iPhone and iPad: the Save your Recovery Key step offers **Copy** and **Save to Files** under the key. Copy puts the key on this device's clipboard only, where it stays for two minutes; Save to Files hands a plain-text file with the key to the system's save panel and keeps no copy. Neither confirms the key (#2616).
- 98348fc: A Favorites or folder move, or a checkmark, made from an order that another Trusted Device has since changed and published now gives way to that change when this device synchronizes, so the other device's reorder is no longer lost. Moves made on one device before it publishes all stay (#2628).
- 884e20c: In a compact iPad window (Slide Over, a narrow Split View or a narrow window) the composer is the
  system sheet, as on iPhone: swiping it down is Close, and it offers no Command Palette. A composer
  keeps where it opened while the window changes width, with its Draft, selection and Undo history
  (#2645).
- 9f819a0: Warnings, such as Authorization Needed and the Pin indicator, are amber in Light (`#9A5B00`) so they no longer look like the cinnabar On device seal. In Dark the unread dot is lighter (`#7A7E88`) and reaches 4.10:1 on the message list. iPad text uses whole-point sizes in place of the 1.15× fractions, and the shared tokens gain 24pt and 40pt spacing steps and lose the unused sheet and duplicate inset-group radii (#2650).

  The On device marker shows the `cpu` symbol in place of the lock, so it no longer reads as Profile Lock or encryption.

- 677485c: On iPad and iPhone, typing `/` at the start of a body block opens the Slash Command Menu with the Basic Blocks: Text, Heading 1 to 3, Bulleted List, Numbered List, Quote and Code Block. Typing filters them; a tap, Return or Tab sets the block and removes the typed command as one Undo step. An iPad hardware keyboard moves the highlight with Up and Down Arrow and closes the menu with Escape (#2656).
- 270175e: On iPad, the reader's More menu lists Move to Spam directly after Mark as Read or Unread and before Move to…, as the approved frame draws it. On iPhone and iPad, mail in Spam offers Not Spam there instead of Move to Inbox; Trash keeps Move to Inbox (#2662).
- 8c26803: On iPad and iPhone, the Slash Command Menu lists Attach File… and Insert Image… under Insert, after the Basic Blocks. Typing filters both sections. Choosing one removes the typed command and opens the same picker as the format bar, which places an inserted image at the caret when it returns (#2668).
- 1f68c5c: A Gmail or Microsoft Inbox whose synchronization the app's return to the foreground interrupted synchronizes again once the restore ends. A newly connected Outlook.com mailbox on iPhone no longer stays on **Loading Inbox** until the app is relaunched (#2676).
- ac45565: On the Mac, Settings gains a Mail group with **Reading**: Text Size follows macOS, and **Message zoom** zooms received formatted mail in the reader from 50% to 300%, kept on this Mac only. The message and Drafts don't change, and an open message keeps its selection as the zoom changes. Remote images further down a message taller than the reader now load as they come near on the Mac too (#2678, #2680).
- 9cba349: On iPad and iPhone, the Slash Command Menu lists the Writing tools that apply after Insert, in the format bar's groups: Generate a Draft…, Suggest Reply on a reply, and the text tools while the body has text. Typing filters them, and choosing one removes the typed command and runs it as the format bar does (#2687).
- aa9ba6e: Outlook.com and Microsoft 365 meeting invitations show the invitation card on Mac, iPhone and iPad, read from the message's MIME, and **Accept**, **Maybe** or **Decline** sends one reply through the owning Microsoft connection. **Check Again** finds an unconfirmed reply in Sent Items by its Message-ID, and the card names the provider Outlook.com or Microsoft 365 (#2703).
- 4b51584: An IMAP folder refresh now fails, keeping the previous folder list, when the mail
  server's session ends during the listing and the new session reports different
  namespaces. Before, one of the ways the mail library logs in again went unnoticed,
  and the listing combined folders from both sessions.
- 2ed2a21: An inline image's size menu now names the image's own size under Original: its width and height on iPhone and iPad, and its width on the Mac, read on the device with the row's thumbnail (#2729, part of #1735).
- b291d02: At the accessibility text sizes Settings rows on iPhone and iPad put their value and controls
  beneath the title, so titles such as Language keep the row's width, and pop-up choices, the
  destinations, the account name and Profile mailbox addresses wrap instead of truncating; account and Profile monogram
  letters keep the circle's size (#2730).
- 9776ab0: An IMAP mailbox whose server times out while the app checks its account again now stays
  offline with its saved mail shown, instead of saying the mail saved on this device can't be
  shown. Work that a registration restore invalidates keeps the open IMAP Inbox, which opens
  again once the restore ends, as a Gmail Inbox already does (#2731).
- 1852c56: On iPhone and iPad, a recipient field whose entry wraps beneath its recipients, as at the largest accessibility text sizes, keeps the entry one line tall, so the composer no longer stretches it to the sheet's height and its recipients and **Show Cc and Bcc** scroll into reach again (#2736).
- c164dce: While Gmail's usage limit pauses a Gmail Inbox until the time Gmail named, registration verification no longer asks Gmail about that connection: activation, Refresh, every Try Again and push wakes skip it, including while its storage is locked or unreadable, and it keeps the access this process verified, so changes made meanwhile are still saved; while any Gmail mailbox is paused, full registration verification also skips push watch renewal for every connection. It verifies again at Gmail's time. `createRegistration` and `createRegistrationFlow` take the `paused` connections, which the host reads from the new `Mailboxes.paused` and Inbox store `paused`; native `forgetMailboxAccess` takes the connections whose access it keeps (#2745).
- fe92fe9: **Forward** and **Attach to New Message** keep a downloaded attachment on the device until the Draft has copied it, so a reader that closes first, as when the iPhone composer replaces it, no longer leaves the file **Not added** (#2763).
- 191b6d3: iPad: Mailboxes shown with **Show Sidebar** stay shown after the text size goes to an accessibility size and back (#2768).
- 4fda2a6: Writing tools can now say when a rewrite needs clarification. A `needs-clarification` rejection from the native model reads as a text-free `{ kind: 'clarification' }` Draft assistance state for Rewrite, Expand Text, Shorten Text, Make More Friendly and Make More Neutral, and as `failed` for every other operation. On Mac, iPhone and iPad the composer shows the approved card: "Couldn’t rewrite this. Your Draft is unchanged — edit your original to make it clearer, then try again." It offers Try Again and Close and leaves the Draft and its Undo history unchanged. The native binding does not emit the code yet (#2776).
- 1f9abc9: A Gmail reader's labels open in native presenters instead of a glass panel: on iPhone, More's
  Labels and the Reply sheet's Labels open a system sheet, and New Label… opens its own sheet once
  that one closes; on iPad, the toolbar's Labels opens a system popover, where New Label… takes the
  labels' place. A tap outside closes either one, as the system does (#2781, part of #1056).
  The labels follow the #1683 frames: a Labels title over the Gmail account, grouped rows with a
  checkmark on applied labels and, on iPad, a folder button to move; New Label's Cancel and disabled
  Apply draw a visible capsule on iPhone too. In Light, the labels and New Label keep the system's glass.
- 00ee1d1: The evaluation composer opens Attach on iPhone, and Writing tools on iPhone and iPad, as system menus, as the regular composer does.
  On iPhone, both composers' Attach and Writing tools menus end at the trailing edge and bottom of the composer controls, which hide while a menu is open, and list their actions top-down. The regular composer's iPhone controls now end 16pt from the trailing edge, as the frames draw them. The iPhone compose sheet shows the system grabber. On iPhone, the evaluation composer's header, From and body sit where the frames place them, and its body text uses the primary text colour. Paste Image shows two pages. iPad and Mac keep their sheet top and editor text as before.
- 7def2c1: On iPhone and iPad, a file that wasn't added names why, or says "Wasn't added", and offers Try Again, which adds the same file again without a picker. An importing file reads "Importing… 64%" with a progress bar, and while it imports the reason above the body names it and VoiceOver reads it with Send (#2795).
- 5f1fa3a: On iPhone and iPad, **Settings › Notifications** lists each Mail Profile with a **Badge and sound** switch. A Profile switched off adds nothing to the App Icon Badge, and its New Mail Notifications play no sound. Every switch starts on and stays on this device; while notifications are off, the group is hidden and the choices are kept (#2809, part of #1723).
- eaa3ffc: On iPhone and iPad, **Settings › Notifications** offers a **New Mail Sound** pop-up under **App Icon Badge** with **Default** (the system notification sound) and **None**. It starts at **Default** and stays on this device. New Mail Notifications play the chosen sound, or none; while notifications are off, the choice stays, dimmed (#2812, part of #1723).
- ae1ee73: Synchronize each Draft's Send Reminder between the Product Account's Trusted Devices through Private Sync (#2830, part of #658).

  - Each reminder is a sealed `send-reminder.` record under an identifier derived from its Mail Profile's and Draft's, holding the Draft and Mail Profile identifiers, the due instant, the time zone and a random write identifier, never Draft content; a removal leaves a sealed tombstone. Native code adds `pullSendReminders` and `pushSendReminder`.
  - `createSendReminders` takes an optional `NativeSendReminderSync` and gains `synchronize`. A reminder set, changed or removed offline is published by compare-and-set once Private Sync is reachable. A removal wins over a concurrent change, and of two concurrent changes the first written wins, so devices converge on one reminder. Cancelling a reminder that has not arrived yet publishes its removal, and cancelling one Profile's reminder never touches another Profile's reminder for the same Draft.
  - The Mac and iPhone/iPad mailbox screens synchronize reminders when they open and when the app becomes active or goes to the background, so a reminder removed by Send or Discard on one device is removed on the others.

- 209dfa9: The assistance qualification build now runs a separate on-device clarification check before Rewrite, Expand Text, Shorten Text, Make More Friendly and Make More Neutral, and its corpus (version 5) adds cases that must and must not ask for clarification. Every other build edits exactly as before until the check qualifies (#2849).
- 9322f52: Drafts now keep tables, with their header cells, merged cells and formatted cell
  text, through saving and reopening. The composers do not show a table yet, but
  editing a Draft's text, subject or recipients no longer removes it, and sent mail
  writes header cells as table headers.

  In mail-core, `DraftSchema.body` is a `TableDocument`; `textOf` gives the text a
  composer edits and `withText` writes an edit back without removing the tables.

- 37dd285: The Tiptap Draft editor page edits a Draft's tables: Tab and Shift-Tab move
  between cells, Tab leaves the last cell without adding a row, Return adds a line
  in a cell, Backspace after a table selects it and a second deletes it as one Undo
  step, and the caret's cell is outlined. A table the page cannot edit unchanged is
  kept as it is. The composers still give the page the Draft's text without its
  tables.

  The page's `draftEditor.document`, its `update` message's `document` and the
  `replace` command now carry a `TableDocument`.

- 972916c: The Tiptap Draft editor page keeps a Draft's alignment, list levels, text colors, backgrounds,
  font families and sizes through opening, editing and saving, and shows them as the current
  composer does, with Dark colors and per-level list numbering. Typing, Return, joined blocks,
  edits of a selection, marks and block kinds keep them as the current composer does; pasted HTML
  still carries none. mail-core's new `body-display` entry
  point holds `formatStyleOf`, `isListKind`, `listNumbersOf` and `markersOf` without a schema
  library, so the page can bundle them; `semantic-document` still exports the first three (#2884).
- 8dd9f59: Open composers show a Send Reminder another device changed (#2897, part of #658).

  - `createSendReminders` gains `subscribe`, which tells a listener after each change this device stores, including a reminder a synchronization pass took from another device, and after each synchronization, so a read that failed meanwhile is made again.
  - The Mac and iPhone/iPad composers read their Draft's reminder again on each change, so a reminder another device set, changed or removed appears in, changes in or leaves an open composer's banner as soon as this device synchronizes.

- b183689: On iPhone and iPad, when the system closes a message link's confirmation without a choice, the
  link is discarded as Cancel discards it, so choosing a link again asks again (#2909).
- cf500a3: A message stays shown in the reader while a composer opens over it and after the composer
  closes: on iPhone beneath the New Message sheet, on iPad above a docked reply or beneath the New
  Message card. It no longer turns into a spinner and lays its body out again, and it keeps its
  scroll position (#2917).
- 1eb19dc: On iPhone and iPad, the Draft editor page of `registration-draft-editor` builds keeps unsaved
  edits in a composer recovery record, as the current composer does, and **Restore** after the app
  ends reopens them in the page instead of the current composer (#2944).
- b9e1782: On iPhone and iPad, the Draft editor page opens the current composer's Slash Command Menu when `/` is typed first in a body block. The menu hangs under the caret's line, the page hands it Return, Tab, the arrows and Escape, and its choice is one page edit that one Undo reverts.
- f6e54e4: On iPhone and iPad, the Send Reminder choices end with Choose Date and Time…, which shows the system's calendar and time in the same sheet or popover. It starts at the Draft's reminder or Tomorrow Morning, refuses days before today and times that have passed, and Set Reminder stores the picked instant with the device's time zone.
- 320d3e9: On iPhone and iPad, a message with a one-click unsubscribe offer shows an Unsubscribe banner naming its mailing list, and **Unsubscribe…** in the reader's More menu. **Unsubscribe…** asks first in a system alert, naming the list and the receiving address, and only **Unsubscribe** sends the request, once. The banner then says the request was sent, dated, or that it failed or got no clear answer, with **Try Again**, which sends again without asking, and **Block Sender…**. A list the Mail Profile asked to leave in the 14 days before the message arrived shows as sent. A message whose only offer is `mailto:` shows neither yet (#2985).

  The `registration-unsubscribe` Mock Mail Session lists three one-click newsletters, and mock builds answer a one-click request with the outcome its URL names.

- 2dd6518: On the Mac, a file that wasn't added keeps its copy while it can be tried again: its row names why, or says "Wasn't added", and offers Try Again, which adds the same file without a picker; while a file imports, the reason above the body names it and VoiceOver reads it as Send's help. Send's question names a received attachment that couldn't be downloaded (#2991).
- bba3bab: Mac, iPhone and iPad offer the same Send Reminder times (#3001): This Evening at
  18:00 while it is still ahead, Tomorrow Morning at 8:00, This Weekend on Saturday
  at 9:00 from Sunday to Thursday, and Next Week on Monday at 8:00. The Mac gains
  This Weekend and Next Week and moves to 18:00 and 8:00, so Choose Date and Time…
  starts tomorrow at 8:00; iPad gains This Weekend. Mail-core's `reminderTimes`
  returns these times and replaces `mobileReminderTimes`.
  The Mac reminder menu shows each time on its title's line, right-aligned, through
  the new menu item `detail`, and wraps its note in small type; the iPhone sheet
  shows its grabber and separates its rows. The iPad popover's Cancel is primary text
  on the quiet fill.
- 7be517a: Update Expo to the 58.1.0 releases `expo install --check` expects (#3007): `expo`, `@expo/ui`, `expo-dev-client`, `expo-glass-effect`, `expo-router`, `jest-expo` and `babel-preset-expo`, carrying the `@expo/ui`, `expo-dev-launcher` and `expo-glass-effect` patches unchanged and moving the release notices' Expo licence supplements to the new versions. Expo Router 58.0.33 makes `@react-native-masked-view/masked-view` an optional peer, so the app, which does not use it, no longer links its native module.
- a7717ba: On iPhone and iPad, the Settings rows that run one action (Enter the Password…, Remove…, Delete, Add Profile…, Duplicate Profile and Remove Profile…) are system buttons, so VoiceOver reads each as one button with its disabled state and the system draws the press feedback (#3029).
- 3966b92: On iPhone and iPad, Error Reporting's Delete My Error Reports and its deletion follow-up (Check Deletion Status, Try Again) are system buttons, so VoiceOver reads each as one button with its disabled state and the system draws the press feedback. A disabled Settings action row now dims to the 45% the frames draw (#3041).
- 932dce0: On iPhone and iPad, Settings push buttons (such as Add Gmail…, Remove and Allow Notifications) are system buttons, so VoiceOver reads each as one button with its disabled state and the system draws the press feedback. A destructive push button keeps its label without a fill, as the frames draw it. A long title wraps inside its group, and at larger text sizes push buttons side by side stack (#3045).
- 757d89c: On iPhone and iPad, a message whose list unsubscribes by email offers Unsubscribe… too: it emails the request from the receiving mailbox through the Outbox, shows it waiting with the Undo Send toast, then sent and dated, refused or unknown, and says when the mailbox must sign in again or receives only.
- d2ff3f5: On iPhone and iPad, the Labels rows that run one action (New Label…, Create “…”, a matching label and iPad's Move to a label) are system buttons, so VoiceOver reads each as one button with its disabled state and the system draws the press feedback (#3061).
- 91a6618: The Move picker's Back, Close and Cancel on iPhone and its selectable folder rows on iPad are system buttons, so VoiceOver reads each as one button and the system draws the press feedback (#3073).

  At the largest text sizes, and after the text size changes while they are open, the Move picker's rows and the Settings action rows fit their labels, truncating a long name with an ellipsis instead of clipping it.

- 22e2d1f: On iPhone, the Reply sheet's Close, tiles and action rows are system buttons, so VoiceOver reads each as one button and the system draws the press feedback (#3074).
- 5dfed4b: On iPhone, a sheet drag that starts on a system button in the sheet, such as the Labels sheet's New Label…, no longer runs that button when the drag is released before the sheet closes (#3077).
- 157176d: On iPhone, the Settings list's account card and destination rows are system buttons, so VoiceOver reads each as one button and the system draws the press feedback. Settings rows that run one action now keep their height when the text size changes while Settings is open (#3079).
- 4b48adb: On iPhone and iPad, Settings › Privacy's Error Reporting row and, on iPhone, each Spam and Trash Folders row in Email Accounts are system buttons, so VoiceOver reads each as one button with its status or folders and the system draws the press feedback (#3080).
- 20dffd7: Forward opens its Draft at once on Mac, iPhone and iPad: each original file that isn't downloaded yet shows as importing while the Draft downloads it, and one that couldn't be downloaded is Not added with Try Again. The reader no longer shows Preparing to forward… (#3119). While a file downloads, saving a Draft and its recovery writes no longer wait for it, so text typed meanwhile survives the app closing.

  The `registration-forward` Mock Mail Session lists a message whose attachment downloads after 30 seconds, to show a forward's importing file in native captures.

- faa5e93: iPhone Move sheet: the folder rows are system buttons, as the iPad popover's already are.
- 50eac67: On iPhone and iPad, the reader's Translate is a system button, so VoiceOver reads it as one button and the system draws the press feedback (#3129).
- 17fe0cf: On iPhone and iPad, Remind Me to Send's **Choose Date and Time…** and, on iPhone, its times are system buttons, so VoiceOver reads each as one button and the system draws the press feedback (#3135).
- 0302409: Refresh dependencies to the latest compatible versions: Effect 4.1.5, Convex 1.51, jose 6.2.18, i18next 27.2 and react-i18next 18.0, parse5 8.1, the CSS parser 4.0.3 and Tiptap 3.34 in the Draft editor page. The Mac app moves to React Native macOS 0.83, with React Native 0.83.10 and React 19.2, and to WebView 14.0.1, the version iPhone and iPad use. In Effect 4.1 a request that waits for a lock can no longer take a free lock ahead of an earlier waiter, so a history backfill step in a Gmail, Microsoft or IMAP Inbox now steps aside for any Inbox request that is waiting, such as a synchronization, a change being sent or Discard Change, so a history read no longer delays them. Each tagged error class now carries a type brand, so another class with the same fields no longer type-checks as it.
- Updated dependencies [ebb70f1]
- Updated dependencies [f6bdbd4]
- Updated dependencies [2b6b0a2]
- Updated dependencies [ce04f2c]
- Updated dependencies [22026ed]
- Updated dependencies [6d21e32]
- Updated dependencies [643fe96]
- Updated dependencies [e662cb5]
- Updated dependencies [fd50bbb]
- Updated dependencies [e015cfb]
- Updated dependencies [e74502a]
- Updated dependencies [6d7c277]
- Updated dependencies [9054e1a]
- Updated dependencies [e6be4e9]
- Updated dependencies [98f27cb]
- Updated dependencies [e1948d0]
- Updated dependencies [d6a124c]
- Updated dependencies [3f2363b]
- Updated dependencies [5246109]
- Updated dependencies [1872d39]
- Updated dependencies [16ef069]
- Updated dependencies [4698039]
- Updated dependencies [dbb1218]
- Updated dependencies [3b19eb2]
- Updated dependencies [44a7672]
- Updated dependencies [c416829]
- Updated dependencies [17eb728]
- Updated dependencies [b981eff]
- Updated dependencies [4a29bf4]
- Updated dependencies [005823d]
- Updated dependencies [fb5b3a4]
- Updated dependencies [21ef44a]
- Updated dependencies [9a7cf95]
- Updated dependencies [d0534ac]
- Updated dependencies [41140eb]
- Updated dependencies [7f14b01]
- Updated dependencies [e49531b]
- Updated dependencies [768201e]
- Updated dependencies [f7ca447]
- Updated dependencies [b2ff343]
- Updated dependencies [d0be5d8]
- Updated dependencies [d7bd630]
- Updated dependencies [f539826]
- Updated dependencies [a1e183e]
- Updated dependencies [0f25336]
- Updated dependencies [811634a]
- Updated dependencies [6a9034c]
- Updated dependencies [1250d61]
- Updated dependencies [98348fc]
- Updated dependencies [9f819a0]
- Updated dependencies [677485c]
- Updated dependencies [270175e]
- Updated dependencies [ce6b413]
- Updated dependencies [8c26803]
- Updated dependencies [1f68c5c]
- Updated dependencies [ac45565]
- Updated dependencies [9cba349]
- Updated dependencies [c95a25b]
- Updated dependencies [a0b02eb]
- Updated dependencies [aa9ba6e]
- Updated dependencies [a8e8d3f]
- Updated dependencies [2ed2a21]
- Updated dependencies [9776ab0]
- Updated dependencies [c164dce]
- Updated dependencies [592aac1]
- Updated dependencies [fe92fe9]
- Updated dependencies [4fda2a6]
- Updated dependencies [00ee1d1]
- Updated dependencies [746507f]
- Updated dependencies [7def2c1]
- Updated dependencies [ea52abb]
- Updated dependencies [f14bf7b]
- Updated dependencies [5f1fa3a]
- Updated dependencies [1ff7a94]
- Updated dependencies [eaa3ffc]
- Updated dependencies [82e8d34]
- Updated dependencies [07d0ee3]
- Updated dependencies [361a4f3]
- Updated dependencies [70e2779]
- Updated dependencies [ae1ee73]
- Updated dependencies [209dfa9]
- Updated dependencies [9322f52]
- Updated dependencies [37dd285]
- Updated dependencies [972916c]
- Updated dependencies [6fef500]
- Updated dependencies [8dd9f59]
- Updated dependencies [a2d2027]
- Updated dependencies [b9e1782]
- Updated dependencies [90c6a63]
- Updated dependencies [33508c9]
- Updated dependencies [a2a2c32]
- Updated dependencies [5dc1d7b]
- Updated dependencies [3c710f3]
- Updated dependencies [f6e54e4]
- Updated dependencies [67a8f0a]
- Updated dependencies [320d3e9]
- Updated dependencies [4e72a1a]
- Updated dependencies [2dd6518]
- Updated dependencies [e343f79]
- Updated dependencies [bba3bab]
- Updated dependencies [e97ad73]
- Updated dependencies [06323ec]
- Updated dependencies [f375899]
- Updated dependencies [d6e84a2]
- Updated dependencies [5df441d]
- Updated dependencies [5df441d]
- Updated dependencies [3e852e6]
- Updated dependencies [2fcf2ba]
- Updated dependencies [27cd600]
- Updated dependencies [432b580]
- Updated dependencies [20dffd7]
- Updated dependencies [c66d1e5]
- Updated dependencies [0302409]
  - @private-email/localization@0.2.0
  - @private-email/mail-core@0.2.0
  - @private-email/draft-editor@0.2.0

## 0.2.0

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

- 27d75cc: Keep an Inbox row that an organizing action removes on screen while it collapses and fades, and grow it back from its current height on Undo or when a refused, rolled-back or discarded change returns it, in every window. A scroll, a selection or another action finishes a leaving row; synchronization never moves rows and keeps a scrolled list's topmost visible row in place (#1091).

  Expose the shared organizing-row continuity projection through mail-core/mailboxes so both hosts use the same outcome and placement rules. Rows follow provider message IDs; an IMAP Inbox snapshot now names the ID each verified move started from (`originalIds`). Provider snapshots name the messages with unfinished changes (`organizing`), including an IMAP Undo still moving back, so a restored row stays the same row and a confirmed removal stays quiet even while another message has unfinished work.

  Preserve Undo motion after a failed IMAP destination refresh and ignore a mobile exit completion delivered after the same row has started returning.

  Wait for the native iPhone Inbox column to finish appearing before its row exits, so a slower Back transition cannot conceal the removal.

  Finish leaving rows when notification navigation selects another message, and preserve synchronized message details throughout a later removal. The shared projection takes each row's stable displayed content through `ShownRows.contentOf`.

- 98b2991: Notify privately for newly arrived Inbox mail from IMAP and Microsoft 365 mailboxes too (#1094). Settings › Notifications lists a switch for every mailbox. IMAP notifies for unread mail at or above the last committed UIDNEXT under an unchanged UIDVALIDITY, received no earlier than the previous synchronization began (less five minutes for provider clocks), so older mail moved in never notifies. Microsoft notifies for unread mail a delta page names that this device had not cached; Graph creates moved mail anew in the Inbox, so it counts as created there unless it is older than a full cache. Listings, a UIDVALIDITY change, an expired delta link and updates to known messages never notify. Mark as Read on a notification acts on IMAP and Microsoft mail as on Gmail, and so does Archive, except that on IMAP it needs the server to declare an archive folder and move without expunging other mail; otherwise it changes nothing.
- 99d10aa: The categorization spike's `Manifest` and `Manifest.Labels` are now `Decodable` instead of `Codable`, and its unused label encoder is gone. Manifests still decode both label shapes.
- bb71ffb: On iPhone and iPad, a message sent just before switching apps or locking the device finishes its Undo Send Window and reaches its provider within the background time iOS grants; otherwise it stays queued with its original deadline until the app is active again.
- c18aa1a: On iPhone and iPad, a queued message can reach its provider during a background delivery task iOS grants while the app is closed but not force-quit, keeping its original Undo Send deadline and submitting once; iOS decides when, or whether, that happens.

  Background tasks also check interrupted sends against Sent without resubmitting, and leave inconclusive outcomes unknown.

- a787e87: On iPhone and iPad, tapping the Sync Status Capsule now opens **Sync Status**: each
  shown connection's provider and address, what it is doing, its history download's
  progress, and its own **Try Again** or authorization action when it needs attention,
  with when the shown mailboxes were last up to date. iPhone shows it in a
  medium-detent sheet with **Done**, iPad in a popover on the capsule.
- 52a62f7: Show when the Inbox was last brought up to date on iPad and Mac (#1444).

  - **Subtitle:** when the shown mailboxes are neither syncing nor offline, the iPad and Mac Inbox subtitle adds how long ago they were last brought up to date, such as `12 unread · Updated just now` or `Updated 5 minutes ago`. With several mailboxes shown, the oldest last update counts. iPhone's one-line subtitle leaves it out.
  - **Recorded per connection:** Gmail, Microsoft and IMAP connections save when their latest completed synchronization started with their encrypted cache, so the time survives relaunch and later failed attempts. Each successful synchronization saves the time, even when no mail changed.

- 6a2e442: Turn on Private Cloud separately for each Mail Profile on iPhone, iPad and Mac. Settings'
  **Privacy & Data** adds a **Private Cloud** group: its **Use Private Cloud** switch is off by
  default, needs that Profile's Mail Assistance, asks for confirmation before turning on and is
  saved only on this device with Mail Assistance Enablement. **Check** explicitly reports whether
  Apple Private Cloud Compute is ready, without generating anything. Mail Assistance Enablement
  now records `privateCloud` Profiles, `privateCloudEnabled` reads them, `setPrivateCloud`
  saves that consent and `getFailedSave` names a failed save; `NativeMailAssistance`'s
  `setMailAssistance` receives the Private Cloud Profiles, and `createPrivateCloudReadiness`
  checks a `NativePrivateCloud`. No operation uses Private Cloud Compute yet.
- fe54ada: Duplicate a Mail Profile from Settings › Mail Profiles on Mac, iPhone and iPad.
  Duplicate Mail Profile creates `<name> Copy` without asking, selects it and
  shows its page for renaming. It copies only the name; mailboxes, sign-ins, mail
  and Drafts stay with the original. A Profile that owns no mailboxes now says so
  in its Mailboxes group and points to moving one from its current Profile.
  Creating a Mail Profile now resolves with the new Profile's identifier, so
  Duplicate opens its own copy even when another creation finishes first.
- efd53e3: Add Proofread, Break into Paragraphs, Expand Text, Shorten Text, Make More
  Friendly and Make More Neutral to the iPhone and iPad composer's Writing tools
  menu, grouped and with the symbols the Mac menu uses. Each runs its own on-device
  model operation on the selection or the whole authored body and opens the same
  review panel as Rewrite, under its own title.
- 5e434b8: Add Generate a Draft… to the iPhone and iPad composer's Writing tools menu. It
  opens a prompt, in a popover on iPad and a sheet on iPhone; Generate asks the
  on-device model to write email text from the prompt alone, and the result opens
  in the review panel, where Insert places it at the caret as one undoable edit
  without replacing text, and Discard closes it.
- 7718b51: The iPhone composer replaces its format bar with a floating pill holding Format
  and Add files, plus a separate Writing tools button. Format puts the Format
  panel where the keyboard was, with Undo and Redo, text styles, marks, the Link
  Editor, lists, quotes and code blocks. Tapping back into the body closes the
  panel. Add files opens a menu with Attach File, Attach Photo, Insert Image and
  Paste Image. iPad keeps its format bar.
- b7fa145: Check iPhone and iPad Writing tools results for the details they change. The
  review panel lists each changed, uncertain, removed or added link, email
  address, amount, number, date, time or quote beside the original (as a table on
  iPad, one line per change on iPhone) with the kept details, and offers **Use
  rewrite with changes** instead of Replace text when anything differs, with Keep
  original as the accent button. Every result notes that the checks compare
  details only.
- c8b8223: The iPhone and iPad reader shows a single Gmail meeting invitation's card and sends Accept, Maybe or Decline to the organizer, with Check Again, Respond Again… in a system alert, and Sign In….
- a3579bc: The Mac, iPhone and iPad readers show a cancelled Gmail meeting as cancelled, with its details and nothing to respond to, instead of saying Unwired can’t read the invitation.
- 6bc653c: When a Gmail meeting invitation names two or more addresses of the same Mail Profile, the Mac, iPhone and iPad readers list each of them under Invited and say which address this copy responds for. The response is still sent only from the opened mailbox.
- d2ce522: The Mac, iPhone and iPad readers show a weekly Gmail meeting series that ends on a date or after a number of meetings, with its meeting times and first and last dates, and one response answers the whole series. When the local weekday or times vary, the card names the first meeting instead of presenting its times as recurring.
- c9acd6e: The Mac, iPhone and iPad readers show a Gmail invitation to one meeting of a series with that meeting's date and a **One meeting in a series** line, and a response answers and is recorded for that meeting only.
- 2d0af86: The Mac, iPhone and iPad readers show an older revision of a Gmail invitation, after a newer one was answered, with an **Older version** badge and **There’s a newer version of this invitation**, and offer no response from it.
- 123f78c: An older revision of a Gmail invitation offers **Show Latest** on Mac, iPhone and iPad, which opens the message carrying the newest revision this device answered. A recorded response now keeps the message it answered; records saved before it have no **Show Latest**. A Gmail online search result that Gmail later deletes no longer stays available to the reader.
- e6af4e1: Composers journal unsaved edits to a recovery record (#2039, part of #1989).

  - The iPhone, iPad and Mac composers keep their unsaved version in the composer recovery record two seconds after an edit and when the app returns to the foreground, retrying a record locked storage refused. Save Draft, Save, Send, Delete Draft, Don’t Save, Discard and a Close that removes or leaves the Draft remove it. Nothing is offered at launch yet.
  - mail-core `journal` writes nothing for a Draft the current Product Account's session never listed, and `forget` takes the closing editor so a record stays for another editor still open on that Draft.

- 4fce0f5: iPhone's Approve this device step waits for approval by itself: under the code, "Waiting for approval…" replaces the Check for approval button, and the device checks every 10 seconds while the step is on screen, without showing progress. A check that cannot finish, such as offline, leaves the step as it was. An Apple sign-in from before launch cannot check silently, so that step keeps Check for approval. "Use Recovery Key Instead", a text button, opens the Recovery Key as its own step, and "Wait for Approval Instead" returns. The registration store adds `checkForApproval`, and a Pending Device's status reports `approvalSignIn` when its check needs an interactive sign-in (#2066).
- 577933f: Mark an unread message read when the reader opens it, on iPhone, iPad and Mac, for Gmail, Microsoft and IMAP mail (#2080). The reader makes the change Mark as read makes once it can change the message, without announcing it, or a refusal of it, and without replacing the latest notice and its Undo. Each opening marks the message once, even when two windows show it, so Mark as unread stands while it stays open. The Gmail and IMAP stores add `readOpened` for this quiet change.
- 63559b4: Set, change and remove a Draft's Send Reminder from the iPhone and iPad composers' Send menu (#2136, part of #658).

  - A long press on Send opens its menu; Remind Me to Send… offers This Evening (18:00, while still ahead), Tomorrow Morning (8:00), Next Week (Monday 8:00) and, on iPhone from Sunday to Thursday, This Weekend (Saturday 9:00) in the device's time zone, from mail-core's new `mobileReminderTimes`, in a sheet on iPhone and a popover from Send on iPad. Choosing one saves the Draft, keeps the composer open and stores the reminder.
  - The composer shows the Draft's reminder in a banner with Change and Remove Reminder, and Send, Discard or an empty Close removes it. A refused write is reported and changes nothing.

- b625cbd: Block and unblock a sender on iPhone and iPad (#2166, part of #655).

  - The reader's sender menu gains Block Sender…, which confirms in the system alert and blocks the sender's exact address for the reader's Mail Profile.
  - Settings › Blocked Senders lists each Profile's Blocked Senders, newest first, with the date blocked and how many arrivals this device moved to Trash; swipe or Edit unblocks one.

- ed4f8c1: iPhone and iPad Settings › Appearance chooses Light, Dark or System (#2168, part of #1727). The choice stays on this device and applies from launch.
- bc23647: Reply from a new-mail notification on iPhone and iPad: the Reply field names the
  receiving address and Send queues a threaded reply with only the typed text, as on
  the Mac. A reply sent while the app is in the background holds bounded background
  time so its Undo Send Window can end and it can reach its provider, and Open Draft
  opens the Draft in the composer. The host's notification action follower reports
  each admitted typed reply.
- b8622de: The iPhone and iPad Other IMAP Account form fills in the servers, ports, security and user name for an address at a catalogued provider (iCloud Mail, Fastmail, Yahoo, AOL, GMX, WEB.DE, mail.com and Seznam) and says so, until the person changes a server setting (#2189, part of #2004).
- f958ad7: Other IMAP Account on the Mac, iPhone and iPad fills in the servers and ports for an address at an uncatalogued domain from the domain's RFC 6186 SRV records, looked up on the device, and says so, until the person changes a server setting (#2200, part of #2004).
- ad88bc7: iPhone and iPad Settings › Appearance chooses each Mail Profile's List density, Comfortable or Compact (#2202, part of #1727).

  - Compact lets a Thread-list row's subject wrap and keeps one preview line at every text size.
  - `createInboxPreferences` keeps each Profile's Inbox preferences in an encrypted device document and synchronizes them as one sealed `profile-inbox-preferences.` record per Profile, merging each preference's latest choice; native code adds `openInboxPreferences`, `commitInboxPreferences`, `pullInboxPreferences` and `pushInboxPreferences`.

- 89e243d: iPhone and iPad reader: **Translate** is a split control in the translation panel (#2232, part of #2050). One tap translates the message into the app language; the arrow opens the other languages the device can translate into, and names the one chosen.
- a6c02e1: Search the Inbox mail saved on iPhone, iPad and Mac by sender name, address or subject, across all Gmail mailboxes or within one. Search reads only this device's encrypted cache, so it works offline and asks Gmail nothing. Each result opens in the reader and says whether its body is already saved on this device or downloads from Gmail when opened. A slower answer for an earlier search never replaces the current results, and a removed mailbox's mail leaves them at once.
- 71e8349: Search Gmail online from the Inbox on iPhone, iPad and Mac. After a search of the mail saved on this device, **Search Gmail for “…”** asks Gmail's own full-text search of the chosen mailbox or of every mailbox, shows the results under **From Gmail** below the saved results, and pages further with **More from Gmail**. Results outside the cached Inbox open in the reader without being saved on this device. A mailbox Gmail cannot search explains why while the other results stay, and an answer for an earlier query, view or Product Account is never shown. Gmail search queries keep a literal `+`.
- e4b6969: Download, open and share received Gmail attachments on iPhone, iPad and Mac (#610).

  - **Listing:** an opened message lists its attachments with names, sizes and availability, without making attachment requests. Rows appear 20 at a time with Show N more for the rest. Gmail can include small attachment bytes in the bounded MIME response needed to open the body; the cache retains only descriptors. The list is kept with the encrypted body, so it also shows offline. Names cannot leave their folder. Very long sender names are reduced before Unicode cleanup. Shortened names keep a short final suffix or use underscores for dots, so an earlier suffix cannot become the file extension.
  - **Download:** each attachment downloads only when asked, through its own mailbox's Gmail connection. It is kept only when its bytes decode to exactly the declared size; incomplete or damaged copies are refused. Downloads can be cancelled and retried, and attachments over 25 MiB are listed without a download.
  - **Open and share:** a downloaded attachment opens in the system's Quick Look preview, or shares through the system share sheet, with only that file.
  - **Cleanup:** downloaded files stay in private Application Support storage, outside backups, bounded to 250 MiB with oldest-file eviction. Reader, message and Inbox cleanup waits until active Quick Look previews and shares finish; those files also stay through eviction and count toward the limit. A download that cannot fit around them can be retried after the presentation ends. Mailbox removal, sign-out, account deletion, device removal and relaunch delete files immediately.

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

- b3e892d: Redesign message reading on Mac, iPad and iPhone to match the design (#902).

  - **Toolbar:** the reader's organizing and response actions are SF Symbol buttons in Liquid Glass groups. The Mac keeps a fixed toolbar above the reading pane: Archive, Move to Trash and Labels or Folders, then Reply, Reply All and Forward, then the remaining actions. iPad places Archive, Labels or Folders, the response actions and More in a fixed toolbar above the reading pane. iPhone floats Archive, Labels or Folders, Reply and More over the bottom of the reader beside a circular New Message button. Reply opens a glass-backed modal sheet offering Reply, Reply All and Forward. More lists the remaining actions in a panel.
  - **Reading pane:** the subject uses Reading Subject, Mac shows the sender and address on one line with the received time trailing, and the body stays at Reading Body. iPhone adds a header with a glass Back pill carrying the mailbox's cached unread count and the truncated subject, an "N Messages" row in the Thread view, and neutral monogram initials beside each message's sender. Thread messages use the same header.
  - **Saved mail:** replies remain available while provider checks are pending or offline. The organizing explanation appears as a quiet notice in scrollable reader content without covering the message or clipping it in the toolbar.
  - **Attachments and links:** received attachments are quiet-fill chips with a document symbol, name, size and actions. Link confirmations are centered modal glass alerts with a link or warning-shield symbol, the title "This link may not be what it seems" for suspicious links, and stacked Cancel, Copy link and Proceed choices. Mac uses a supported window-level overlay that dims the list and reading pane together, hides background accessibility, and retains the selected mailbox and message ownership checks.

- 4184ccf: Redesign composing on iPhone, iPad and Mac to match the design: the body comes
  first, then attachment chips and the Subject, To, Cc and Bcc rows; the format bar
  uses SF Symbols with a Text style menu; From is a pop-up menu; and the
  regular-width iPad and Mac composers overlay the reader with Expand and Collapse
  instead of replacing it. Selecting another message keeps the open Draft and
  updates the reader underneath it. On iPhone, leaving the composer or a reader,
  including through the Command Palette's Inbox and Search Mail, returns to the
  Inbox instead of an empty reader. On iPhone and iPad, closing or discarding an
  untouched New Message closes the composer instead of leaving "This Draft is not
  available."
  The iPad Commands pill uses a 44pt glass touch target.
  Closing or discarding an untouched Mac Draft also clears its composer after removal.
  The floating search bar hides while composing; Mac Search Mail reveals it while
  keeping the Draft open. The iPad overlay follows the current reading column as
  native sidebars move or hide.
  Starting New Message immediately after selecting an iPad Inbox row keeps that
  latest reader selection when the Draft closes, even before navigation renders.
  Save status and error or confirmation notices scroll with composer content, while
  platform formatting and sender/Send rows remain fixed. Close, Send and Discard
  cannot overlap a pending Close save, including queued callbacks and later typing.
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
- d6d8ffa: Settings no longer replaces the Inbox. On the Mac it is one independent window, opened from
  the app menu's Settings… (Command-,), the Account button, the Command Palette or an IMAP
  password repair; opening it again brings that window forward on the destination asked
  for. iPhone pushes Settings onto a native stack with edge-back, while iPad opens its
  two-column workspace over the kept Inbox; Open Inbox also returns. Opening Settings no longer closes an open composer, so Drafts,
  mailboxes and selected messages are kept, and Settings closes when no Inbox can open.
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
- 43b0b57: On iPhone, Reply in the reader grows a floating glass sheet out of the button (#969). It shows the sender's initials, name and message preview beside a Close button, then Reply, Reply All, Forward and Archive tiles and the Thread's other organizing actions in grouped rows, beside the toolbar's More, and shrinks back toward the button when closed. Reader menu panels and the composer's pop-up menus now ease in from their control and fade out on iPhone, iPad and Mac, and Folders on iPhone opens a Move picker that grows out of the button the same way: the mailbox's address, the message's sender and subject, folders with their role symbols (the current one unavailable) and a search field at the bottom. With Reduce Motion, menus and sheets only fade.

  Move search keeps its results visible in landscape with the software keyboard open.

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

- dfab40f: Add Google Product Sign-In and separate, resumable device-local Gmail authorization in both native hosts. Validate Gmail grants before connection, retain accounts after interrupted consent, and keep Google refresh credentials off the backend.
- 7c38123: Link Google and Apple as verified alternate sign-ins for one Product Account. Linking reverifies the current sign-in, issues a short-lived single-use ticket bound to the Trusted Device, and completes only after the other identity signs in recently. It never merges accounts, matches by email or turns a Gmail mailbox into a sign-in. Either provider then opens the same account, and `productAccount:connect` reports its Sign-In Providers and rejects reconnects that would reach another account.
- 819d141: Connect more than one Gmail mailbox on iPhone, iPad and Mac. The account page lists each mailbox with its state, adds another with Gmail consent, and asks before removing one. Adding a Google account that is already connected authorizes it again instead of duplicating it. Each mailbox keeps its own Gmail access, encrypted cache, waiting changes and synchronization, so a refused grant in one mailbox never blocks reading or organizing another. The Inbox shows every mailbox together, newest first in a stable order with each row naming its mailbox, or one mailbox at a time. Removing a mailbox deletes its Gmail access and saved mail from this device, marks it removed in private sync so other trusted devices remove it too, and leaves its mail in Gmail. A mailbox saved before this change keeps its cache and waiting changes.
- 30b173c: Organize Gmail mail from the Inbox on iPhone, iPad and Mac: mark as read or unread, star, archive, move to Trash, report spam, add or remove labels, move to a label, and undo the latest removal. Each action uses Gmail's labels, shows at once and is saved in the encrypted cache while awaiting a result, so outages and relaunches keep saved changes and send them in order later. If only the saved Inbox becomes available before a change can be saved, it rolls back and the Inbox announces that the request could not be saved; reconnect, then repeat it. Confirmation, permanent refusal or an explicit discard removes the pending change. Gmail refusing a change shows the message as Gmail has it and says so; labels changed in Gmail arrive through history. The reader has keyboard-accessible action buttons and label checkboxes, and the Inbox offers Undo after a removal. VoiceOver offers the common actions on each Inbox row and announces every action's outcome. Native code writes the Gmail request and keeps the mailbox credential. A device found removed while organizing opens the account page's removal explanation.

  Competing store instances keep a change pending while its attempt is running, so a later reversal cannot be overtaken by a duplicate write. Completed failures can be retried immediately, including from another instance or after relaunch.

- 7048de3: Initialize End-to-End Encrypted Product Sync for a new Product Account. The first Trusted Device creates device-held keys, publishes a Recovery Key envelope through the new `productSync:initialize` mutation, and presents the Recovery Key until its final group is confirmed. Initialization succeeds only for an account with no key material, so a device without local keys for an existing account enters enrollment instead of replacing them. The authorized Gmail mailbox descriptor round-trips as an encrypted record bound to its account, identifier, key epoch and schema.
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

- b06ac2f: Ship both hosts as "Unwired Mail" under the `dev.unwired.mail` bundle identifier with
  the new app icon. The Mac host runs in the App Sandbox when signed, both hosts declare
  exempt-only encryption, and each takes its version from its `package.json`.
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

- 344da8a: Update Expo 57 compatibility patches (expo 57.0.30, expo-router 57.0.28, babel-preset-expo 57.0.16) required by dependency validation.
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
- a9ca061: The Command Palette fades in over 200 ms while its panel arrives 8pt from above, and fades out over 150 ms when it closes, on iPhone, iPad and Mac. A closing palette takes no further input, reopening it while it fades starts afresh, and Reduce Motion keeps only the fade.
- a332a26: Show a single Back in the iPhone reader. A message opened from the Inbox showed
  an extra system Back on its own row above the reader's own Back and unread
  count. The reader now uses the navigation bar's system Back, with the mailbox's
  unread count on a disk beside the chevron as in Mail, and keeps the subject on
  its own row below the bar. The edge swipe back still returns to the Inbox.
- ae543f5: On iPhone, Mailboxes now fills the screen: its surface reaches behind the
  status bar and home indicator instead of leaving black bands above and below
  the list, and in landscape its rows keep clear of the Dynamic Island.
- 7a9018b: A configured launch on iPhone, iPad and Mac now opens the Inbox when a Trusted Device
  has lost its local keys and only optional Recovery Key entry remains. **Unlock private
  data on this device** stays available in Settings under **Account & Devices**. Recovery
  Key confirmation, an unanswered removal's replacement Recovery Key, device approvals,
  unsaved mailboxes, locked storage and unfinished sign-out or deletion still open the
  account page first.
- f359f49: Open Inbox in Settings now shows the kept Inbox when Settings was opened from
  Mailboxes on iPhone (Account, Manage Mail Profiles or an IMAP password repair),
  rather than returning to Mailboxes the way Back does.
- f608e2b: While a launch reads the saved registration, the app shows Welcome's breathing seal and **Opening your mail…** instead of Welcome, so an installation with a Product Account no longer flashes Welcome before its Inbox or setup.
- 542ba64: Keep the iPhone reader's selection aligned with native Back navigation. Completing
  Back returns to the originating Inbox or search, while cancelling an edge swipe
  keeps the reader open in place. An open Draft stays open.
- 91b33ea: The iPad Move picker is now a system popover on the reader toolbar's Folders: iOS presents and dismisses it, closes it on a tap outside or Escape, and keeps it clear of the keyboard (#1074).
- e4526a7: The iPhone Move picker is now a system sheet: iOS presents and dismisses it, keeps its search above the keyboard, and lets you swipe it down to close (#1074).
- f585db4: Announce Send outcomes to VoiceOver on iPhone, iPad and Mac. Each change of where
  an Outbox message stands, and each Check Again answer that leaves delivery unknown,
  is announced once however many Mac windows show it. The composer announces a refused Send, a Draft that
  could not be saved on Close or Discard, and the Discard question.

  Outbox status and Check Again announcements wait for existing VoiceOver speech.

- 99482cc: Show the connected Inbox on iPhone again. Since Settings moved onto a native stack
  above the Inbox, the Inbox opened as an entirely black window after setup and on
  later launches. It now waits for its stack screen to join the window before
  mounting the split view, so the Mailboxes, list and reader appear.
- b5deba1: The iPhone Reply sheet is now the system sheet: iOS presents and dismisses it, it can be swiped down to close, and it fits its actions, scrolling when they don't fit (#1118).
- 3f6507c: Inbox Filters open in the native SwiftUI sheet on iPhone and compact-width iPad, and in a native popover on the Filter control in a regular-width iPad window. The theme drops the unused `radius.popover` token, since the system popover owns its corner radius.
- f561120: Removing a Trusted Device on iPhone and iPad now asks in the system alert: iOS presents it, moves VoiceOver focus to it and returns focus afterwards, and its message scrolls at large text sizes (#1120). The theme drops `scrimMac`, which only that removed custom confirmation used.
- 64aac67: Choose the iPhone and iPad interface language from a native menu picker in Settings' Language, with an explanation of System Default, and on the Sign In page. The Inbox list footer and the setup page no longer show the language options.
- 30169b7: iPhone and iPad choose the translation language from a native pop-up menu instead of a grid of custom language buttons. Opening the menu chooses nothing; the chosen language is checked and named on the pop-up.
- 8fae3a1: Update Expo to 57.0.31 and Expo Router to 57.0.29 with their required native dependencies to restore SDK compatibility checks.
- 4b314a8: On-device summaries and rewrites ask for the language of the message or authored text (#1164). When it confidently identifies that language, the native binding names it to Apple's model and rejects an unsupported language or a confidently detected output language switch as `unsupported-language`. The preview explains the limitation and mail and Drafts stay unchanged. Rewrite instructions forbid added subject lines, greetings and signatures. The assistance qualification corpus is now version 4, with heuristic checks for language switches and added letter framing. Generated text still needs human review.
- 0515aca: Keep the iPhone composer's format bar directly above the software keyboard while the body is edited. The full-window composer no longer applies the safe-area insets twice, which had pushed the bar behind the keyboard and left extra space above the header.
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
- 9db4ef4: Secondary text, including section headers, captions and timestamps, uses the approved solid colours: `#4F4F54` in Light and `#B0B0B5` in Dark. These improve contrast on the documented opaque surfaces. Remaining Mac contrast-audit failures, including the Dark sidebar, are tracked in [#1550](https://github.com/unwired-dev/product/issues/1550).
- 71e9d17: Show the system navigation bar on iPhone Settings pages pushed over the list,
  so Back and the edge swipe return to the same place. Error Reporting now pushes
  over Privacy in the same stack, and the Welcome screen's Privacy page uses the
  system Back too. Back's history menu returns to the chosen page, and the
  Command Palette still opens from the Settings list's title.
- a35a049: Name reader controls without repeating their role. A blocked image without a description
  shows and reads "Image not loaded" in the app's language instead of showing "Image" under an
  image label, kept to one line within a small sender-sized placeholder, and each message link's keyboard control is named by the link's text or
  destination instead of "Open link: …" and is underlined like other links.
- 07adfcb: On iPhone, returning from the Inbox to Mailboxes by Back or a leading-edge swipe no longer
  leaves an empty navigation bar above Mailboxes, so its heading stays directly below the status
  bar, and a cancelled swipe keeps the Inbox's bar with its Back and title (#1223, #1247).
- cf070fb: Text actions in the reader and composer, such as Summarize, Translate, Load Images, Cc/Bcc, Retry and the Outbox's Undo and Edit, now show feedback while pressed and focused. Pressing one shades it with the subtle selection color. The framework keeps mouse and touch feedback visible for at least 130 ms after press-in, so a quick release or cancellation can leave the highlight visible briefly. Keyboard focus draws a 2 pt accent ring around it, and composer text actions can now be reached by keyboard. Disabled actions stay grey. The labels keep their positions, sizes and hit targets.
- 6ca2c54: Push buttons on Mac, iPhone and iPad show the approved pressed, focus and disabled states: the accent fill lightens to 80% and the quiet fill takes the selection tint while pressed, keyboard focus on the Mac draws a 2 pt accent ring in place of the system ring, and disabled buttons dim to 40%.
- 9335b84: iPhone and iPad custom controls rely on the system keyboard focus indicator and no longer carry an app-drawn focus ring, which never appeared.
- b9376c3: Show the iPhone Inbox's title and status line in the system navigation bar, whose
  Back returns to Mailboxes. A leading-edge swipe from the Inbox now returns to
  Mailboxes too, and a swipe released early keeps the Inbox. The bar hides while
  searching.
- 1b1f82c: iPhone Mailboxes shows a glass New Message at its bottom corner and opens Settings from Account in its header, as the updated frames show. Settings' list of destinations gains a leading Back to what it covers, such as Mailboxes, and closing a Draft started from Mailboxes returns there.
- 2221b0b: A message list row directly above a date divider no longer draws its own separator
  line, on Mac, iPhone and iPad.
- 434a315: Draft rows in the Inbox list and Command Palette rows fill with the subtle selection color while pressed, on iPhone, iPad and Mac. On the Mac, a focused Draft row shows the 2pt accent ring in place of the system focus ring.
- 63bf13b: The launch Restoring screen's seal stops breathing when Reduce Motion is turned on while it shows, and resumes when it is turned off, on Mac, iPhone and iPad.
- 0177565: On iPhone and iPad, the composer's Send button shows its fill at 80% while pressed and dims to 40% while unavailable, and Close responds with the native Liquid Glass press and dims its symbol while unavailable.
- d65b96e: Settings explains a remote-content choice it couldn't save: the pop-up keeps the saved choice and a warning under the row, announced to VoiceOver, says what is still set until the next change. Clear Saved Remote Content shows Clearing… with an activity indicator, and Check Deletion Status shows Checking deletion status… with an indicator, each disabled while it runs, on Mac, iPhone and iPad.
- 4cda3ac: When storage refuses to return an Outbox message to the Drafts, a toast above the search bar says so with Try Again, and VoiceOver hears it at once. When Check Again finds a message in Sent, VoiceOver hears that it is in Sent, on Mac, iPhone and iPad.
- 230328c: In Settings, Mail Profile rows, Add Mail Profile…, Remove Mail Profile… and the Error Reporting entry fill with the subtle selection color while pressed, on iPhone, iPad and Mac. On the Mac, a focused row shows the 2pt accent ring in place of the system focus ring.
- b7fc9a4: Removing a mailbox in Settings keeps its confirmation open while the removal runs: Remove shows Removing… with an activity indicator, and Remove and Cancel are disabled. If the mailbox could not be removed, the confirmation stays with a warning, announced to VoiceOver, that says it is still connected and, when this Mac, iPhone or iPad is offline, says so; Remove and Cancel are enabled again. A removal that applied before its reply failed closes as removed. If its outcome cannot be read back, the confirmation stays with an uncertainty warning and allows retry without claiming the mailbox is still connected.
- 5093483: VoiceOver hears a ready summary, translation or Rewrite result once, after what it is already saying, and hears an assistance failure or refusal at once, on Mac, iPhone and iPad.
- e122954: Settings › Mail Profiles shows a queued change while it runs. The control that
  started it shows an activity indicator: a move to Family reads **Moving to Family…** on the Mac, and the indicator replaces the pop-up on iPad and iPhone.
  Add Mail Profile…, the Name field, the mailbox pop-ups and Remove Mail Profile…
  are disabled until the change completes or fails. Disabled Settings rows now dim
  to 40%.
- cc0e828: A valid Gmail connection no longer shows **Gmail needs your permission again**
  when the app returns to the foreground during synchronization. While the
  foreground account check verifies the connection again, its mailbox and body
  reads are pending rather than refused, and the saved Inbox stays shown until the
  synchronization after the check. A grant Gmail actually refuses still asks for
  Gmail access.
- bbefd8d: Lower the iPhone Inbox floating bar to 4pt above the bottom safe area, and 12pt above the software keyboard while searching, as the approved frames place it.
- a5549f0: Run the iPhone reader and Thread view to the screen's bottom edge, and lower the reader's floating toolbar and New Message to 2pt above the bottom safe area, as the approved frames place them.
- e5614a1: Log why a New Mail Notification was or was not posted, without mail content or identifiers.
- d5badea: Gmail mailboxes download the metadata of their whole All Mail history in the background once the Inbox is current, 100 messages per page, into encrypted history segments beside the mailbox cache. The download resumes after relaunch or an interrupted page, keeps later Gmail changes, and starts a new pass that keeps the earlier history visible when Gmail's history ID expires. Scrolling past the newest 200 messages of the Inbox or a Gmail view reveals older downloaded mail without asking Gmail, and the Gmail Inbox state reports downloaded messages, Gmail's total and whether the history is complete.

  Messages outside the saved cached views open on demand without saving their bodies. An open still succeeds if synchronization moves the message out of those views while its body downloads.

- 1c52450: While a Gmail connection's history is still downloading, its All Mail subtitle shows how much has downloaded, such as "41,210 of 86,400 downloaded", and All Mail ends with a "Downloading older mail…" row that names the month the list has reached instead of the note that older mail stays in Gmail.
- beba12c: When Translation cannot list its languages, the reader and Draft translation say “Translation languages couldn’t be loaded.” with Try Again on Mac, iPhone and iPad; a device without translation languages still says translation is not available.

  On Mac, retrying keeps the reader banner visible with Loading languages, a small activity indicator and Try Again disabled. A failed explicit retry is announced in the reader and Draft menu.

- 4863942: VoiceOver hears Settings failures and outcomes shown as alert text, such as a refused Recovery Key, a language that could not be saved or the result of Clear, at once on Mac, iPhone and iPad.
- b888f97: Onboarding controls show the approved feedback. On iPhone and iPad, Continue and Sign in with Apple show their fill at 80% while pressed and the other sign-in actions take the subtle selection fill; Back is interactive glass with the native glass press. On the Mac, the sign-in action takes the subtle selection fill while pressed, and the sign-in action, provider rows and the Privacy link draw a 2pt focus ring in place of the system ring.
- 0061fa2: “Search mail servers for …”, “More from mail servers” and “Search mail servers again” in online search, and “Try again” in the reader, are text actions on iPhone, iPad and Mac: they fill with the subtle selection color while pressed and, on the Mac, show the 2pt accent ring in place of the system focus ring. Message link controls fill with the subtle selection color while pressed, and on the Mac their accent border replaces the system focus ring.
- b4b5ff6: Keep only the native Liquid Glass press for toolbar buttons inside glass, such
  as the reader toolbar and the iPhone composer pill, instead of stacking a
  pressed fill on it. Toolbar buttons outside glass keep their pressed fill.
- 4726e97: Show pressed and focus feedback on composer recipient tokens and the Show and
  Hide quoted text toggles in the composer and the mobile reader. Tokens fill
  with the subtle selection colour while pressed, draw the accent focus ring and
  dim while the draft cannot be edited; the quoted-text toggles are text actions.
- 553b10f: Make each Mail Assistance switch in Settings a plain system switch, like the
  other settings switches. Pressing beside it no longer toggles Mail Assistance
  without pressed feedback.
- 6c8fed2: Remove More from the iPhone reader toolbar when the Reply sheet offers its actions, and add a
  Labels row to the Reply sheet that opens Gmail's label checkboxes. Mail without Reply keeps More.
- 85bbda1: Show the Sync Status Capsule above the iPhone and iPad Inbox bar: it counts
  accounts still updating, measures All Mail's history download, and replaces
  per-mailbox "could not be reached" notices with one attention summary and
  Try Again for the unreachable mailboxes. A Gmail history download paused by a
  failed read now reports `paused` and asks for Try Again instead of showing progress.
  Authorization failures remain in Attention alongside their access-repair notices,
  including when a refresh interrupts an unfinished history download.
- 04ea6ef: On iPhone, the evaluation composer's **Translate into** pop-up is as tall as its label again, so the translation and **Replace** stay on screen instead of being pushed below it.
- 4c60a49: While a message's body loads on iPhone and iPad, the reader shows the same toolbar it shows once the message opens, with Reply, Reply All and Forward unavailable until the message is ready. The iPhone toolbar no longer switches from More to Reply when loading ends. A message whose body cannot open still offers More.
- be70a4f: On iPhone and iPad, Try Again and pull to refresh synchronize an IMAP connection while another folder is listed, so a recovered connection leaves the Attention state instead of staying in it (#1478).
- c37df0e: On iPhone, the Inbox's floating Search bar now rises and falls with the keyboard
  as Search opens and closes, instead of jumping above the keyboard before it
  arrives.
- 1449697: Keep the iPhone Filters and reply sheet content in place while a swipe slides the sheet away, so the Inbox floating bar stays in view instead of disappearing under the bare sheet and sliding back in.
- d900ce2: On iPhone, the composer and the evaluation composer now rise and fall with the
  keyboard as it appears and hides, instead of jumping above it before it arrives.

  On iPad, collapsing an expanded composer clears its keyboard avoidance padding.

- 3b73a74: On iPhone, Inbox rows now scroll under the floating bar to the screen's bottom
  edge, across the home indicator, instead of stopping at the bottom safe area. The list's scroll indicator stops
  at the floating bar, including while searching above the keyboard.
- bcbf72f: A press on an Inbox bar notice, such as the Sync Status Capsule, no longer cancels when the
  finger moves slightly while the keyboard opens. The bar and its notices now follow the
  keyboard by layout, so the press region matches where they are drawn.
- 7004e1a: Microsoft mailboxes download the metadata of their Inbox, Sent Items, Archive and own folders in the background once the Inbox is current, 50 messages per page, into encrypted history segments beside the mailbox cache. The download resumes after relaunch or an interrupted page, keeps new, moved, deleted and read mail current through each folder's delta link, and lists a folder again, keeping its earlier history counted, when Graph expires that link. The Microsoft Inbox state reports downloaded messages, the folders' total and whether the history is complete, so the Sync Status Capsule includes it; throttling pauses the download until the next synchronization.
- 03f2f8c: On iPhone and iPad, an `unwired-mail://` link opened while the composer is open asks to save or delete the Draft first, and a composer that cannot close keeps its edits and drops the link.
- fa78d42: iPhone's Inbox puts Filter, search and New Message in the system toolbar, with the native integrated search field.
- 98b2e05: The registration-draft-editor Tiptap evaluation editor keeps a Draft's links through editing, saving and reopening, and shows linked text in the link color. Text typed inside a link joins it and text typed at its edges stays unlinked. A pasted link keeps its destination only when it is a web, mail or telephone address the Draft admits as written; any other pasted link keeps only its text.
- 373fbc2: Underline linked Draft text and edit or remove a link's text and destination with the Link Editor on Mac, iPad and iPhone.
  Keep invalid pasted link labels out of the Draft so link edits remain saveable.
- b6b3f58: Remove a link from anywhere in the iPhone Edit Link sheet's Remove Link row, not only its label.
- af46ca8: The registration-draft-editor Tiptap evaluation editor edits and removes a Draft's links with the current composer's Link Editor on Mac, iPad and iPhone. Each Apply and Remove Link is one Undo step in the page.
- 1ed6c4b: After Select All, the registration-draft-editor Tiptap evaluation editor's format bar shows the block kind of the first selected block, so a Draft that is one numbered list keeps **Numbered list** selected.
- fcec6f4: Add a link to selected unlinked Draft text with the Link Editor on Mac, iPad and iPhone, and name an invalid link destination after Return or on leaving the Link field.
- 13d15bf: Offer Rewrite, Translate and Suggest reply from one Writing tools menu in the iPhone and iPad composer.
- 9b7af97: The registration-draft-editor Tiptap evaluation editor adds a link to selected unlinked text with the current composer's Link Editor on Mac, iPad and iPhone. Apply is one Undo step in the page, and a selection the page has changed since the editor opened stays unlinked.
- 5a3cc75: Store a Draft in the iPhone and iPad composer only on Save Draft or Send, and ask with Delete Draft and Save Draft when Close would leave changes.
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
- 1830892: Mail Profiles Settings marks the selected Mail Profile with the subtle selection fill, a press stacking a second over it, and Welcome's Privacy & Data link fills while pressed on Mac, iPad and iPhone.
- 584f11f: Add Generate a Draft… to the Mac composer's Writing tools menu. It opens a
  popover for a prompt; Generate asks the on-device model, through its own
  `generate` operation, to write email text from the prompt alone, and the result
  opens in the review panel, where Insert places it at the caret as one undoable
  edit without replacing text. The assistance core exports `canGenerate` and
  `capturePrompt` for the prompt-only `generate` operation.
- 8355a0d: iPhone and iPad Settings › Mail Profiles choose a Profile's Color and Icon from
  system pull-down menus after its name, and list each Profile with its styled
  monogram. The Primary Profile shows Graphite and First Letter. Shared menu
  items accept a `symbolColor`, which iPhone and iPad menus draw as the symbol's
  color.
- dbb566f: The iPhone and iPad Profile Switcher and Profile Menu show each Mail Profile's
  styled monogram: a circle in its Color with its Icon or first letter in white,
  the Primary Profile in Graphite. The switcher no longer shows two-letter
  initials, and mail-core drops `profileMonogram`.
- 7eed086: Show a Draft's stored alignment, fonts and colors in the iPhone and iPad
  composer, adapting low-contrast colors for Dark on screen only.
- d22c2b8: iPad: an open Generate a Draft prompt and an open Link Editor keep what was typed when the composer
  window resizes between the iPad and iPhone layouts, and appear again in the new layout.
- 442a59b: Move the iPhone and iPad app to Expo SDK 58 with React Native 0.88.1 and React
  19.3.0, and update Expo Router, Expo UI, Screens, safe-area, keyboard-controller,
  WebView, Reanimated and Worklets to the SDK 58 versions. The app now uses Expo's
  scene lifecycle, which forwards Google sign-in callbacks to the app delegate.
- bc6c49e: Leave an IMAP connection out of All Mail, with a notice, until its server marks one Junk and one Trash folder, so All Mail no longer lists its Spam and Trash.
- ed443c8: On iPhone and iPad, the Inbox of a Mail Profile that owns no mailbox is subtitled
  "No mailboxes" instead of Gmail and its status, and shows No Mailboxes with
  Manage Mail Profiles…, which opens Settings › Mail Profiles.
- f6e2099: On iPhone and iPad, Edit Link opens the link that ends a reopened Draft when the caret is still where the Draft opened with it, after the body.
- 611e189: On iPhone and iPad, an IMAP connection left out of All Mail because its server marks no Spam or Trash folder offers Choose Folders… in its notice, a sheet for choosing those folders by name. A ready IMAP Inbox state now reports the Spam and Trash folders its server marks itself as `marked`. A chosen folder no longer takes a role the server marks on several folders, so none of those folders loses it. Move to Inbox is offered from every folder the server marks as Spam or Trash, even when it marks several.
- 461ba87: On the Mac, an IMAP connection left out of All Mail because its server marks no Spam or Trash folder offers Choose Folders… in its notice, an AppKit sheet for choosing those folders by name with the same rules as iPhone and iPad. `@private-email/mail-core/mailboxes` now exports the shared folder choice model (`folderChoice`, `startingPicks`, `ambiguousFolders`) that both clients render. When the server marks only one of the two folders, the Mac and iPad sheets are titled "Choose a Spam Folder" or "Choose a Trash Folder", as the frames show; iPhone keeps "Spam Folder" or "Trash Folder".
- a90be5c: A Gmail invitation that moved the meeting after you answered it shows an Updated badge, the earlier time and your earlier answer on Mac, iPhone and iPad, and asks you to respond to the new time.
- 94555c2: iPhone: the Command Palette lists its commands again beneath the query field, scrolling within the sheet's height.
- da46f67: On iPhone and iPad, Settings › Email Accounts lists each IMAP connection whose server leaves Spam or Trash unmarked under Spam and Trash Folders, warning that it is not in All Mail until both are chosen and naming the chosen folders afterwards; Choose Folders… or Change… opens the same folder sheet as the All Mail notice. `@private-email/mail-core/mailboxes` now exports `folderSummary` for that row.
- 5bbb2bd: On Mac, iPhone and iPad, a Gmail invitation response whose mailbox is removed from Unwired while it sends shows Not sent with the removed address and no response buttons, and is never sent from another mailbox.
- ba8db0b: On Mac, iPhone and iPad, editing a Draft while a Writing tools rewrite is being made or waits to be used now replaces the rewrite with a card saying it wasn’t used and that the text is as the person left it. Rewrite again runs the same tool on the current text, and Close dismisses the card.
- d93343d: On Mac, iPhone and iPad, a Gmail invitation update that names one meeting of a weekly series but also carries the series' rule says Unwired can’t tell which meeting it is and offers no response, instead of saying it can’t read the invitation.
- 123b68e: On iPhone and iPad, invitation responses keep their titles on one line. When the row cannot fit them, such as the chosen response's checkmark in iPad's narrow three-column reader, they stack at full width instead of wrapping into tall circles.
- 4b4d45d: iPhone Settings › Email Accounts: an IMAP connection's Enter the Password… and Remove… are rows of their own below its address, so the address no longer wraps one character per line.
- c2992fc: Bundle third-party notices before signing and align app privacy manifests with
  reviewed SDK declarations, synchronized content and optional diagnostics.
- a04184c: Declare the collected data types from the App Privacy answers in the Mac, iPhone
  and iPad privacy manifests.
- 41ed7c5: Suggest recent correspondents in the iPhone and iPad composer's To, Cc and Bcc fields.
- d66cef4: Start New Message from the Mail Profile's Default Sending Identity, even when it cannot send on this device, instead of the first usable mailbox.
- c1145ac: Suggest Apple Contacts after recent correspondents in the iPhone and iPad composer's To, Cc and Bcc fields, once Contacts access is granted.
- 37d4273: Paint every sender text decoration in the reader, including inside links, in the app's text color at the automatic thickness, so a colored or thick line cannot hide part of a link's label.
- 03cb431: Keep composer recovery records in device-local encrypted storage (#2031, part of #1989).

  - Native storage keeps one encrypted record per composer for the signed-in Product Account. Records stay on this device, never enter the Drafts document or Product Sync, and keep the files and images they name through saves until removed. Removing one needs no key, another account never reads them, and every account purge removes them.
  - mail-core Drafts gain `journal`, `forget` and `recovered`. A record refused while storage is locked is written with the next one. The composers do not write records yet.

- 5bd4eef: Add the Templates control to the iPhone and iPad composers: insert one of the Draft's Mail Profile's templates as one Undo step, or save the Draft's subject and body as a new template.
- a45d7b8: Open a Writing tools text tool's review over the whole iPad window, as Expand
  does, so its progress, review and outcome show full screen without dimming.
- f261850: Count composer recovery records in the Outgoing Content Store's 100 MB (#2054, part of #1989). A record that would exceed it is refused and leaves the record it would replace, and a Draft save or attachment is refused when records leave too little space.
- b0526e2: Add Settings › Signatures on iPhone and iPad: give each Sending Identity a formatted signature, stored and synchronized through Product Sync, or clear it (#2059, part of #850).
- ea1498c: iPad Settings returns to mail with a 44pt glass Back button at the top of its sidebar, named "Back to Mail", in place of the Close Settings `xmark`. Before sign-in the same button returns to Welcome in place of the "Back to Welcome" sidebar row (#2067).
- 11edb4c: The iPhone Inbox heading says "All read" when nothing is unread, as its frames draw it; iPad and Mac keep "No unread messages" (#2068).
- 939c098: On iPhone and iPad, the Recovery Key steps' action is white on brand deep (Confirm Recovery Key and Unlock with Recovery Key), and Confirm Recovery Key stays disabled until a character is entered. iPad draws both steps on brand deep at its onboarding sizes (#2070).
- aec666a: On iPad with the sidebar shown, the "Filtered by" control centers with the search field and stays clear of the sidebar, and the Filters popover lines up with its leading edge.
- d8b3de6: On a compact-width iPhone the reader's text fades out beneath its toolbar, and a Thread's opened message is tinted only while the Command Palette targets it, on iPad too (#2089).
- 24ea6e7: Mac, iPad and iPhone show an SF Symbol on each Add a Mailbox provider tile in place of a letter: `envelope` for Gmail and Fastmail, `icloud` for iCloud Mail, `building.2` for Microsoft 365 and Outlook and `at` for Other IMAP Account (#2093).
- 1481615: iPhone Outbox rows draw Undo, Edit and Check Again as 44pt quiet capsules on a line under the row's reason, as the approved Outbox frames show; the unknown outcome's Cancel and Edit Anyway follow. iPad rows keep their text actions (#2098).
- 54084ba: Show IMAP meeting invitations that need no response on Mac, iPhone and iPad: a cancelled meeting, an invitation for another address, a series update that names no one meeting and an invitation Unwired can't read (#2109, part of #1279). An invitation the IMAP mailbox could answer still shows no card.
- 9ac5048: Say on Mac, iPhone and iPad that a receive-only IMAP mailbox can't respond to a meeting invitation, with Mailbox Settings… to set up sending (#2114, part of #1279). Nothing is sent from another address.
- 3c99e9e: iPhone and iPad confirm a message link in the system alert instead of a custom glass overlay (#2155, part of #1056). The alert shows the full destination, lists a flagged link's warnings, and closes without acting when its message changes.
- fa7939a: On iPhone, More in the reader toolbar opens the system menu iPad's More opens instead of a custom glass panel of buttons, ending with Delete Message (#2158, part of #1056). Its Labels item opens Gmail's label checkboxes.
- 9db4728: iPhone and iPad composers open the system menu from From and Compose actions instead of a custom in-flow menu (#2160, part of #1075). From checks the chosen sender while it can send, and Discard still asks before discarding the Draft.
- 1c30cfb: Replace the app icon with "Horizon" in Graphite & Cinnabar: an open envelope
  seen edge to edge with the cinnabar seal rising from its pocket. The icon has
  its own Light and Dark drawings, and in Clear and Tinted the seal stays the
  brightest shape.
- 66aed69: At the accessibility text sizes on iPhone and iPad, Inbox rows, the iPad Inbox title and sidebar, and the reader's subject and sender wrap instead of truncating; the reader stacks its sender, address and date; and the one-time Command Palette hint and the mailbox notices scroll with the messages (#2191, part of #2007).
- a5813d9: Include the publisher's MIT licence for standard-navigation in the bundled
  third-party notices, and keep Expo patch-release notices complete.
- 2431cdf: At the accessibility text sizes the iPhone and iPad composer puts each field's label above its
  value and lets the From pop-up wrap; the iPad card moves From to its own row, and the format bar
  keeps its size (#2230).
- 80dab93: The iPad sidebar shows a Mailbox Connection's problem as a warning triangle beside its
  section header, including a connection waiting for authorization, and VoiceOver reads the
  problem with the header. The connection's Inbox row keeps its unread count, and the list
  subtitle names a connection that needs sign-in after the count (#2243).
- 97681a6: iPad popovers open without an arrow, beside the control that opened them.
- 834fea8: Mac, iPad and iPhone use one name per action: Delete instead of Move to Trash or Delete Message, Move to… instead of Move Message, Move to Spam instead of Report Spam, and Try Again instead of Try again, Retry, Retry change, Retry deletion, Search mail servers again or Try saving assistance choice again; VoiceOver names retry buttons “Try Again to …”. All Mail's note says Spam instead of Junk, a disabled Command Palette command asks to select a Thread instead of a conversation, and the Sign In heading reads "Sign in to Unwired Mail" (#2257, part of #2083).
- ced407b: On Mac, iPad and iPhone the On device marker heads a summary, translation or Draft assistance result as "<Kind> · On device" (Summary · On device, Translation into English · On device, Shorten Text · On device) instead of a sentence; the sentence saying it was made on this device, may be inaccurate and is not saved follows the result as secondary text (#2259, part of #2083).
- f1e4c88: Mac, iPad and iPhone offer the provider's star only from the Command Palette, as Star and Remove star: the Mac reader toolbar, the iPad and iPhone More menu and Reply sheet, the row and reader context menus and VoiceOver's row actions no longer show it, and rows no longer carry a flag or say "Flagged". The folder chooser names a virtual `\Flagged` folder's role Starred (#2265, part of #2084).
- 5de33f2: iPad: Sign in with Apple has 6.9pt corners like the button beside it, the setup sheet 25.3pt corners, and the Profile Switcher a 28pt monogram.
- 586bdc2: Update Expo to the 58.0.26 patch releases `expo install --check` expects (#2284): `expo`, `@expo/ui`, `expo-dev-client`, `expo-router`, `jest-expo` and `babel-preset-expo`, carrying the `@expo/ui` and `expo-dev-launcher` patches unchanged.
- ed25cbe: Mac, iPad and iPhone explain a Writing tools result that didn’t finish for a reason the app can’t name: the Writing tools panel now says the suggestion didn’t finish, that your text is unchanged, and to choose Try Again to get writing help, instead of only "The suggestion could not be created." When a long reply leaves no room for the quoted message, Suggest Reply now says so and suggests shortening the reply, instead of the same failure message without a Try Again button (#2307, #2308, part of #2006).
- 2905769: Type @ in an otherwise empty iPhone or iPad composer body to open Recipient
  Suggestions under it. A tap, or a hardware keyboard's Up and Down Arrow then
  Return or Tab, chooses a person: they join To and the query becomes a greeting,
  an empty paragraph and the caret, as one undoable edit. Suggestions come from
  recent mail of the Draft's Mail Profile and Apple Contacts the app can already
  read, without asking for Contacts access.
- 264cc20: A composer recovery record keeps the stored version its edits started from (#2332, part of #1989).

  - `journal(draft, origin)` stores `origin` as the base of the unsaved version, and `recovered()` returns `{ version, base }` records; a record written before this change returns its version alone.
  - The iPhone, iPad and Mac composers journal the version they last stored, leaving it out while that save is pending or failed.
  - On the Mac, **Restore** saves against that version, so a Draft another composer saved before the app ended keeps its version and the restored edits become a conflicting copy. A record without one saves against the Draft as listed, as before.

- 3584987: Composer recovery keeps the previous run's records as read when the account's storage opens, so a later lock no longer hides them for the rest of the run, and closing a Draft before its record is offered no longer removes the record (#2334, part of #1989).
- 88cf0c5: On iPad and iPhone, Pin and Unpin a message's Thread: iPad's reader toolbar shows Pin before More, iPhone lists it in the reader's More menu and Reply sheet, and both offer it in the row and reader menus, VoiceOver's row actions and the Command Palette. Every row of a pinned Thread shows a pin and VoiceOver says Pinned. Pins stay on this device and never change a provider flag or star (#2343, part of #2084).
- 330bdec: iPhone Settings rows use the iOS text styles: subtitles are Footnote 13/18, rows pad 13pt so a push button row is at least 62pt and a switch row at least 56pt, push buttons are 36pt, row symbols sit in a 24pt slot, and the Language and Remote Message Content pop-ups show their choice in Body beside a 22pt circle (#2344, part of #2088).
- 1b24dcc: A narrow iPad composer, such as the 442pt Portrait reader, folds its format bar as the Portrait frames draw it: each crowded section ends with an overflow menu. More Formatting holds Underline, Strikethrough and Inline code; More Lists and Links holds Numbered List, Add Link or Edit Link (whose Link Editor opens from the menu), Undo and Redo; More Files and Templates holds Attach Photo, Insert Image, Paste Image and Templates (#2357, part of #2095).
- dfd4dc7: iPad Portrait hides Mailboxes when the columns sit side by side; at 834×1210 the 391pt list sits beside a 442pt reader inset 23pt, with the Thread flat between separators, as the Portrait frames draw it; Show Sidebar brings Mailboxes back.
- c6efc35: iPad Settings: Add Mailbox Connection… and Add Mail Profile… show a plus and Known Tracking Pixels an eye, so every row in their groups has an icon (#2362, part of #2097).
- c15d0e0: On iPad the sidebar toggle, the Command Input and the reader toolbar share one centre line, 36pt beneath the top safe area: the reader toolbar moves down 5.3pt, the preview reader's read button takes the toolbar's 1.15× size, and the sidebar toggle moves up 0.85pt, as the approved frames draw them (#2363).
- ee99e36: Refuse Gmail messages nested more than 32 MIME levels deep or with more than
  10,000 parts instead of exhausting the stack while reading them. Inspect a
  link's painted text apart from admitted image descriptions, so an image's
  alt text cannot mask a mismatched address. Render a message's replacement
  presentation after an earlier rich view failed.
- ee99e36: Recheck message ownership before showing link confirmations in either host.
  Hide invalidated confirmations and reject queued link choices after the message
  or account changes, so a previous owner's destination cannot be revealed.
- ee99e36: Preserve requested Content-Type and Content-Disposition headers in Mock Mail Session prefetch responses so synthetic attachment fixtures retain their exclusion metadata.
- b45a92b: Show unsaved Draft changes and a Save Drafts retry action in the Inbox when saving fails or private storage is locked. On iPhone, selecting the current Draft reveals its composer again. Compact native Back can still hide an unsaved composer; its transition protection remains required before release.

  Return no new Draft identifier when the Product Account changes before creation finishes.

- b45a92b: Preserve body formatting across mobile forward deletion and ignore repeated New Message presses while a Draft is being created.
- b45a92b: Keep each composer bound to its own conflicting Draft through continued typing,
  Undo, Redo, storage recovery and Discard. Preserve the newer stored version's
  identity, and group subject typing by words at the caret.
- b45a92b: Preserve To, Cc and Bcc roles in Draft list text and accessibility labels on iPhone, iPad and Mac, so a Bcc-only Draft no longer appears addressed To someone.
- b45a92b: Keep each Draft's From address visible alongside its body preview in the Inbox.
- dfc1f46: Preserve Draft files through attachment-only Close, Undo after image import and
  Discard racing a later edit. Clean abandoned or failed picker copies and keep
  received-attachment creation from changing a newer navigation destination.
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
- 0668ad3: Discard queued reader translation controls when their preview is dismissed, so
  they cannot restart translation or close or cancel a later preview.
  Cancel and Retry controls for a superseded request also leave its replacement alone.
- 6976e75: Authenticate native push relay requests with the verified Product Account session as well as the Trusted Device proof, allowing device registration and Gmail watch setup to reach the authenticated backend.
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

- 86d3924: The registration-draft-editor Tiptap evaluation editor ignores a late page report of an earlier body revision, so a delayed message can no longer replace newer text before or during Save Draft, Save or Send.
- e34e9d2: Add the categorization-spike page to the iPhone and iPad build of that Mock Mail Session scenario, which runs the frozen DeBERTa candidates through Core ML on bundled samples. The Mac page now shares its session with it. Production and every other build keep the empty reader.
- 36780c7: Decode message bodies in legacy single-byte charsets, including Czech
  `windows-1250` and `iso-8859-2`, on iPhone, iPad and Mac instead of showing
  garbled UTF-8 text.
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
- 35e6141: IMAP folder listing stops reading once a server sends more than 1,000 LIST
  responses and closes the session, instead of collecting the whole answer before
  refusing it; the oversized list keeps prior cached mail for retry, as before.
  SwiftMail moves to the upstream revision that adds this bound. With it, SMTP
  connections wait up to five minutes for the server's greeting, as RFC 5321
  recommends, instead of five seconds.
- b996c70: A successful Send now always closes the composer on iPhone, iPad and Mac, even when
  the sent Draft leaves Drafts before Send finishes. The composer no longer stays open
  on "This Draft is not available." A refused Send still keeps the composer open with
  its reason.
- a59ebbb: Drafts and Mail Assistance follow the Mail Profile that owns their connection. A Draft's
  Rewrite, Suggest reply and Translate use that Profile's consent, and a request is retired
  whenever the connection moves to another Profile. Settings offers one Mail Assistance
  switch per Profile; with only the Default Profile it is unchanged. Each window lists only
  its own Profile's Drafts and Outbox. Moving a connection keeps its Drafts, the queued
  message and its delivery claim.
- 6dce6b9: New Message stays usable when starting a Draft rejects unexpectedly, for example
  because a Draft subscriber throws. The Inbox button on iPhone, iPad and Mac and
  the compact reader's New Message button reset after the rejection instead of
  doing nothing until the view remounts.
- 3d62e75: On iPhone, the Inbox shows Back to Mailboxes and its title and status line in one header row instead of below an empty navigation bar, and the Inbox surface fills the status bar and home indicator areas.
- 417d4f8: Keep wide HTML email readable on iPhone and iPad. Desktop-width tables and blocked
  remote image placeholders now narrow to the reader column instead of clipping text
  at its right edge, and content that still needs more room, such as unwrappable
  text, scrolls sideways inside the message. `decodeMessageContentHeight` is replaced
  by `decodeMessageContentSize`, which also returns the measured width.
- 112140d: Close the reader's More menu, and iPad's Move panel, when the person taps outside it (#966). The tap no longer reaches the message, a link or the header beneath while the panel is open.

  Selecting another message in the same reader now starts it with its panels closed.

- 6c2a31c: Render iPhone and iPad Liquid Glass with Expo's provided glass view. Toolbar
  glass groups, including the Inbox search, filter and New Message controls and the
  reader's action group, are now interactive with their controls inside the
  material, and no opaque fill hides scrolled content behind them.
  Taps in reader toolbar padding still reach the open menu's dismissal layer.
- d4d70b6: On iPad, the Inbox's search bar along the bottom of the window rises above the software keyboard again while you search (#969).
- b304d02: Keep fast typing intact in the iPhone and iPad Inbox search field. The field no
  longer echoes each keystroke back from the Inbox's render, which could drop or
  reorder characters typed while results updated. Close Search still empties it.
  Recreating the field after mailbox access returns keeps a closed query empty.
- ea74f94: Summarize shows the summary as readable prose on iPhone, iPad and Mac. Apple's
  on-device model answered with the JSON request's fields wrapped around the
  summary. The model is now asked for plain prose, and a result that is still a
  serialized object fails as a summary error instead of showing.
- e37e290: Opening Reply on iPhone now closes the reader's More menu, or its open Move or Labels panel, so only the Reply sheet is shown and closing it reveals nothing stale beneath (#972).
- d1477d3: On iPhone, swiping back from a Settings destination now returns to the list of destinations, as its Back button does, instead of closing Settings.
- 3b4504a: On iPhone, swiping back from a message now leaves it as **Back** does, so the Inbox no longer keeps
  it selected and opening the same message again shows it (#976).
- 5b0f682: Rich email bodies now follow the app's Light or Dark appearance on iPhone, iPad
  and Mac instead of showing a white canvas in Dark mode. The reader uses the
  shared content background, primary text and link colors, restyles an open
  message when the appearance changes, and still removes sender colors (#977).
- c38911a: Pull down the Inbox list on iPhone and iPad to synchronize the shown mailboxes and their listed view, with the system refresh indicator until synchronization settles.
- a0e94a2: Keep a list started with `- ` in the iPhone and iPad composer, and continue it on Return, when typing faster than the composer redraws.

  Keep word-sized Undo steps while native text is ahead of the display, and expose that typing classification with the semantic edit.

  Replace selected list markers only when they are included in the field's selection, whether or not its display has caught up.

- 1c6c663: Stop the composer's save status from blinking while you type. Successful saving
  on iPhone, iPad and Mac no longer shows **Saving…** or **Saved on this device**;
  the composer only says when an edit is not saved, because saving failed or
  private storage is locked, and keeps its existing recovery.
- 345e914: The iPhone and iPad Command Palette now scrolls its last commands above the software keyboard, so every command can be seen and tapped while the query is focused (#982).
- ac97a50: Mail sent after relaunching the app with a Sign in with Apple account no longer
  stays in the Outbox on "Waiting to send". The delivery claim is now proven by the
  Trusted Device's own credential instead of a Product Sign-In, which Sign in with
  Apple cannot renew without asking. Builds from before this change keep sending
  when they hold a device credential.
- db3ddaf: Update Expo 57 compatibility patches required by dependency validation.
- b45a92b: Build Draft row previews from a bounded excerpt at the start of the body, avoiding
  full-body strings when the Inbox opens or a body edit refreshes its row.
- b45a92b: Bound Draft row metadata, composer titles and From previews before displaying or
  announcing them, identify shortened metadata in accessible names, and decide
  whether a Draft is empty without joining its whole body. Full authored content
  stays available for editing and saving.
- b45a92b: Save an edit made while a failed Discard waited behind a conflict copy as that
  copy's next version instead of an extra conflicting Draft.
- dfc1f46: Show bounded Draft image thumbnails while keeping verified files without a decodable preview available.
- b45a92b: Preserve same-account late Draft edits as conflict copies after deletion, keep
  edits accepted during a failed discard, and allow navigation to retry after an
  unexpected composer save failure.

  Leave unchanged editor content alone when another writer saves a newer Draft,
  without creating a stale conflict copy. Expose the shared composer navigation
  coordinator for both hosts.

- 83442e2: Update Expo 57 compatibility patches (expo 57.0.32, expo-router 57.0.30, expo-glass-effect 57.0.5 and their companions) required by dependency validation, carrying the glass hit-testing patch forward.
- 26f2a78: Update Expo 58 compatibility patches (expo 58.0.24, expo-router 58.0.31, @expo/ui 58.0.28 and their companions) required by dependency validation, carrying the BottomSheet mounting patch forward.
- 426d8ac: Update to the Expo 58 patch releases dependency validation requires (expo 58.0.25, expo-contacts 58.0.11 and expo-dev-client 58.0.20), with the development launcher patched to build with the Xcode 27.0 SDK.
- dfc1f46: Preserve the image type of selected extensionless Draft files when system metadata leaves it unknown.
- d4bc7ee: Fix Google and Apple sign-in linking rejecting fresh identities when Convex omits the reserved JWT issue-time claim. Validate freshness from the gateway-authenticated bearer token in HTTP actions, retain internal ownership transactions, and explain that the current provider is verified before the provider being linked. Rebuild the native hosts with the matching backend deployment.

  Load local host configuration for Mac native builds, use the active Ruby gem executables, and generate automatically signed Apple Development projects. Preserve Google SDK diagnostics in the private native log.

- a426f0a: Add installation-local, opt-in error reporting with safe exception details and bounded breadcrumbs, consent revocation, and verified remote deletion. Native crash collection remains disabled pending platform qualification.
- 262ac82: Keep registration and the mailbox usable when this device's Product Sync keys
  cannot be read. Restore, sign-in and Gmail authorization now report Product Sync
  as unavailable instead of failing and recording a mailbox failure, keep the
  unreadable keys unchanged, and log Product Sync errors by domain and code only.
- 6a839f1: Never overwrite a Product Sync mailbox descriptor this device cannot open. A
  record with a newer schema, a key epoch this device lacks or failed
  authentication is left unchanged and not shown; only a missing descriptor or a
  readable, different one is replaced.
- 15988d9: Preserve private Inbox storage and report locked storage while iOS protected data is unavailable.
- e40c764: Copy inspected message links through Expo Clipboard on iPhone and iPad and the
  maintained React Native Clipboard module on Mac, replacing the deprecated core
  API while preserving message ownership checks.
- 982d813: Keep Mac Outbox delivery running independently of windows and pause new iPhone and iPad handoffs outside the foreground, preserving durable claims, Undo Send deadlines and uncertain outcomes.
- 15988d9: Persist preview Inbox read state in native encrypted storage. Keep encryption keys and synthetic credentials in device-local Keychain storage, preserve data on storage failures, and share committed changes across independent Mac windows.
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
- 5e69518: Reject TestFlight archives when tracked changes or non-ignored untracked files are present.
- b45a92b: Release a closed composer from the Draft store, so a window closed while saving
  fails no longer stays in memory or follows later conflict copies; its unsaved
  edits are still saved.
  A pending Close or Discard keeps following its own version until it finishes,
  including when its window closes during a conflicting save.
- dfc1f46: Keep unavailable Draft storage visible and retryable when attaching a downloaded file from the reader.
- a1bc55d: Show a locked state instead of onboarding when the app launches while the device
  is locked, and restore the saved account once the app becomes active after
  unlock. Restore also verifies unlocked accounts on every activation, preserving
  setup feedback when the restored status is unchanged. Only unavailable protected
  data is reported as locked; a missing Inbox
  key or another Keychain failure is reported as unavailable, since unlocking
  cannot recover it.
- 5e69518: Stamp release hosts with their TestFlight build number and source commit.
- a973cb6: Upload TestFlight Hermes source maps and dSYMs to PostHog EU, and ship Hermes bytecode in the Mac release archive.
- 7772222: Refresh Expo, Expo Router, Babel preset and development client patch versions to the current Expo 57 compatibility recommendations.
- 15988d9: Update Expo compatibility patches for the mobile app.
- 611c8d3: Add isolated deterministic Mock Mail Session providers and native runners for the open, mark-read and encrypted relaunch journey. Keep scenario selection and cleanup outside the apps and exclude test providers from ordinary bundles.
- 3d8b483: Add a locally packaged plain-paragraph Tiptap Draft editor for the isolated registration-draft-editor evaluation scenario, saving through the existing Draft store. Production and other scenarios retain the current composer.
- Updated dependencies [edac772]
- Updated dependencies [07d8147]
- Updated dependencies [3184c0f]
- Updated dependencies [b5bd44a]
- Updated dependencies [0c7e666]
- Updated dependencies [8eb88f2]
- Updated dependencies [ecdc0ee]
- Updated dependencies [5bbede1]
- Updated dependencies [30829e8]
- Updated dependencies [2b51737]
- Updated dependencies [b9f0c48]
- Updated dependencies [a1c0ccb]
- Updated dependencies [ee887ce]
- Updated dependencies [4b9a4b8]
- Updated dependencies [7a9018b]
- Updated dependencies [f608e2b]
- Updated dependencies [27d75cc]
- Updated dependencies [98b2991]
- Updated dependencies [3f6507c]
- Updated dependencies [f561120]
- Updated dependencies [64aac67]
- Updated dependencies [844cf27]
- Updated dependencies [4b314a8]
- Updated dependencies [f2d35d2]
- Updated dependencies [ea786e3]
- Updated dependencies [149d61b]
- Updated dependencies [e953984]
- Updated dependencies [c6b0be9]
- Updated dependencies [c509c4b]
- Updated dependencies [b337451]
- Updated dependencies [bbd0635]
- Updated dependencies [9db4ef4]
- Updated dependencies [6bb7771]
- Updated dependencies [a35a049]
- Updated dependencies [2fba864]
- Updated dependencies [5e27303]
- Updated dependencies [bb71ffb]
- Updated dependencies [dee8006]
- Updated dependencies [d65b96e]
- Updated dependencies [4cda3ac]
- Updated dependencies [e451786]
- Updated dependencies [b7fc9a4]
- Updated dependencies [e122954]
- Updated dependencies [cc0e828]
- Updated dependencies [e5614a1]
- Updated dependencies [d5badea]
- Updated dependencies [1c52450]
- Updated dependencies [b139883]
- Updated dependencies [85bbda1]
- Updated dependencies [a787e87]
- Updated dependencies [1a7cb66]
- Updated dependencies [52a62f7]
- Updated dependencies [12d2688]
- Updated dependencies [6a2e442]
- Updated dependencies [aa6fe44]
- Updated dependencies [7004e1a]
- Updated dependencies [f1d4a0f]
- Updated dependencies [fe54ada]
- Updated dependencies [98b2e05]
- Updated dependencies [373fbc2]
- Updated dependencies [c22af1b]
- Updated dependencies [05bf301]
- Updated dependencies [2cb0905]
- Updated dependencies [d6ea20d]
- Updated dependencies [10ed643]
- Updated dependencies [1ed6c4b]
- Updated dependencies [1023672]
- Updated dependencies [b956ddf]
- Updated dependencies [f65981f]
- Updated dependencies [fcec6f4]
- Updated dependencies [13d15bf]
- Updated dependencies [9456102]
- Updated dependencies [8e90910]
- Updated dependencies [d30a3e6]
- Updated dependencies [d0de90a]
- Updated dependencies [584f11f]
- Updated dependencies [99f0818]
- Updated dependencies [8355a0d]
- Updated dependencies [e29e359]
- Updated dependencies [2cdecde]
- Updated dependencies [dbb566f]
- Updated dependencies [dbc72c6]
- Updated dependencies [d952552]
- Updated dependencies [f5e94fb]
- Updated dependencies [bc6c49e]
- Updated dependencies [ed443c8]
- Updated dependencies [b7fa145]
- Updated dependencies [e0a141c]
- Updated dependencies [c8b8223]
- Updated dependencies [611e189]
- Updated dependencies [a3579bc]
- Updated dependencies [6bc653c]
- Updated dependencies [461ba87]
- Updated dependencies [a90be5c]
- Updated dependencies [d2ce522]
- Updated dependencies [c9acd6e]
- Updated dependencies [2d0af86]
- Updated dependencies [123f78c]
- Updated dependencies [da46f67]
- Updated dependencies [5bbb2bd]
- Updated dependencies [d93343d]
- Updated dependencies [90be0d8]
- Updated dependencies [a19492a]
- Updated dependencies [d33a594]
- Updated dependencies [86b7197]
- Updated dependencies [0cdc2f0]
- Updated dependencies [26f2a78]
- Updated dependencies [b8c880b]
- Updated dependencies [e480f20]
- Updated dependencies [d66cef4]
- Updated dependencies [dbfbe42]
- Updated dependencies [6776b70]
- Updated dependencies [37d4273]
- Updated dependencies [832ac86]
- Updated dependencies [03cb431]
- Updated dependencies [ae1f039]
- Updated dependencies [322acf8]
- Updated dependencies [e6af4e1]
- Updated dependencies [33b4d9d]
- Updated dependencies [8dd21c4]
- Updated dependencies [5bd4eef]
- Updated dependencies [90ce1f1]
- Updated dependencies [0cae86c]
- Updated dependencies [426d8ac]
- Updated dependencies [4fce0f5]
- Updated dependencies [ea1498c]
- Updated dependencies [11edb4c]
- Updated dependencies [bc7467c]
- Updated dependencies [970b373]
- Updated dependencies [577933f]
- Updated dependencies [54084ba]
- Updated dependencies [9ac5048]
- Updated dependencies [56700cb]
- Updated dependencies [836327e]
- Updated dependencies [f93ec59]
- Updated dependencies [e8772e0]
- Updated dependencies [91362c1]
- Updated dependencies [63559b4]
- Updated dependencies [03229b6]
- Updated dependencies [af0289b]
- Updated dependencies [b625cbd]
- Updated dependencies [ed4f8c1]
- Updated dependencies [20ba841]
- Updated dependencies [9de3fc7]
- Updated dependencies [eaef12e]
- Updated dependencies [bc23647]
- Updated dependencies [dfd883c]
- Updated dependencies [f958ad7]
- Updated dependencies [ad88bc7]
- Updated dependencies [5b9a677]
- Updated dependencies [50c416a]
- Updated dependencies [6e13ab3]
- Updated dependencies [b013505]
- Updated dependencies [6e8cfb3]
- Updated dependencies [2599daf]
- Updated dependencies [49c2c3a]
- Updated dependencies [40a45a6]
- Updated dependencies [e407c5a]
- Updated dependencies [49553ad]
- Updated dependencies [1de6c21]
- Updated dependencies [e71fdfb]
- Updated dependencies [834fea8]
- Updated dependencies [ced407b]
- Updated dependencies [31685f4]
- Updated dependencies [fb1f986]
- Updated dependencies [f1e4c88]
- Updated dependencies [35cd0c5]
- Updated dependencies [ea2f7e2]
- Updated dependencies [97bce84]
- Updated dependencies [a3f7570]
- Updated dependencies [5de33f2]
- Updated dependencies [0e752cc]
- Updated dependencies [e22e832]
- Updated dependencies [ee5b308]
- Updated dependencies [685f0d7]
- Updated dependencies [bd5e9c4]
- Updated dependencies [c478fa5]
- Updated dependencies [cd7b3d5]
- Updated dependencies [2a0d6e7]
- Updated dependencies [9301b0a]
- Updated dependencies [4956d41]
- Updated dependencies [7d63e3d]
- Updated dependencies [ed25cbe]
- Updated dependencies [4ea2360]
- Updated dependencies [8e78f00]
- Updated dependencies [77c6958]
- Updated dependencies [dcf3dc0]
- Updated dependencies [d80cbe8]
- Updated dependencies [585ad82]
- Updated dependencies [d2af682]
- Updated dependencies [0cb8504]
- Updated dependencies [b62b0fd]
- Updated dependencies [2905769]
- Updated dependencies [264cc20]
- Updated dependencies [ba91f57]
- Updated dependencies [3584987]
- Updated dependencies [7243117]
- Updated dependencies [6d508f9]
- Updated dependencies [ee99e36]
- Updated dependencies [ee99e36]
- Updated dependencies [ee99e36]
- Updated dependencies [ee99e36]
- Updated dependencies [ee99e36]
- Updated dependencies [a6c02e1]
- Updated dependencies [71e8349]
- Updated dependencies [e4b6969]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [dfc1f46]
- Updated dependencies [dfc1f46]
- Updated dependencies [dfc1f46]
- Updated dependencies [dfc1f46]
- Updated dependencies [f6bf0cb]
- Updated dependencies [1ccb9af]
- Updated dependencies [1ccb9af]
- Updated dependencies [506964e]
- Updated dependencies [8e745d8]
- Updated dependencies [3beb5f5]
- Updated dependencies [0c85d0a]
- Updated dependencies [3afd931]
- Updated dependencies [a39391a]
- Updated dependencies [0668ad3]
- Updated dependencies [0668ad3]
- Updated dependencies [ce247aa]
- Updated dependencies [5a4d34c]
- Updated dependencies [e3660b6]
- Updated dependencies [c70cb72]
- Updated dependencies [e135c7c]
- Updated dependencies [02bb862]
- Updated dependencies [ebcb577]
- Updated dependencies [a182684]
- Updated dependencies [a182684]
- Updated dependencies [e9230a2]
- Updated dependencies [e2db13e]
- Updated dependencies [6509f5d]
- Updated dependencies [4a4f5cc]
- Updated dependencies [a285337]
- Updated dependencies [043d25c]
- Updated dependencies [77d3937]
- Updated dependencies [6ee2629]
- Updated dependencies [4ff7648]
- Updated dependencies [452fec1]
- Updated dependencies [ddb3700]
- Updated dependencies [7aba467]
- Updated dependencies [a7a53a6]
- Updated dependencies [2dae6d7]
- Updated dependencies [01ed01c]
- Updated dependencies [e35b687]
- Updated dependencies [3f028f0]
- Updated dependencies [d802688]
- Updated dependencies [02178a0]
- Updated dependencies [b4a3aae]
- Updated dependencies [e34e9d2]
- Updated dependencies [36780c7]
- Updated dependencies [d25bf63]
- Updated dependencies [5fc6fc9]
- Updated dependencies [1225b7c]
- Updated dependencies [72a884f]
- Updated dependencies [5e9492b]
- Updated dependencies [8b23735]
- Updated dependencies [648cce3]
- Updated dependencies [a3293d1]
- Updated dependencies [2bd7060]
- Updated dependencies [fab7a42]
- Updated dependencies [fd7bf6b]
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
- Updated dependencies [e909300]
- Updated dependencies [a59ebbb]
- Updated dependencies [f7962f2]
- Updated dependencies [3d62e75]
- Updated dependencies [417d4f8]
- Updated dependencies [43b0b57]
- Updated dependencies [9aafacb]
- Updated dependencies [76fd227]
- Updated dependencies [5b0f682]
- Updated dependencies [a0e94a2]
- Updated dependencies [1c6c663]
- Updated dependencies [8d15586]
- Updated dependencies [84a6f8d]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [dfc1f46]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [b0b3267]
- Updated dependencies [d4bc7ee]
- Updated dependencies [a426f0a]
- Updated dependencies [dfab40f]
- Updated dependencies [262ac82]
- Updated dependencies [7c38123]
- Updated dependencies [ffb5ae2]
- Updated dependencies [23c0080]
- Updated dependencies [2fed635]
- Updated dependencies [819d141]
- Updated dependencies [30b173c]
- Updated dependencies [b45a92b]
- Updated dependencies [30b173c]
- Updated dependencies [982d813]
- Updated dependencies [15988d9]
- Updated dependencies [7048de3]
- Updated dependencies [b45a92b]
- Updated dependencies [b45a92b]
- Updated dependencies [ed92255]
- Updated dependencies [ee99e36]
- Updated dependencies [b45a92b]
- Updated dependencies [e1d65f9]
- Updated dependencies [9612f48]
- Updated dependencies [b45a92b]
- Updated dependencies [e135c7c]
- Updated dependencies [34651eb]
- Updated dependencies [685494c]
- Updated dependencies [a1bc55d]
- Updated dependencies [2d82cf4]
- Updated dependencies [e4bdb26]
- Updated dependencies [e201a9a]
- Updated dependencies [611c8d3]
- Updated dependencies [3d8b483]
- Updated dependencies [6f28fe0]
  - @private-email/mail-core@0.1.0
  - @private-email/localization@0.1.0
  - @private-email/draft-editor@0.1.0
