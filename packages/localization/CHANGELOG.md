# @private-email/localization

## 0.2.0

### Minor Changes

- ce04f2c: Message dates follow the device's time zone instead of UTC. The reader's header on Mac and iPad
  says `Today, 8:12`, `Yesterday, 8:12`, `Sun 11 Oct, 21:14`, or the date with its year, in the
  interface language's conventions; iPhone's compact header names the day as its list row does.
  VoiceOver reads the full date and time. Message rows, the list's day dividers and Only Mail from
  Today use the same day, which changes at local midnight and with the device's time zone. The
  native language settings now report `timeZone`, and `messageDateSections` and `filterMessages`
  take it. A response still quotes a full UTC date for a message without a Date header (#2102).
- 0f25336: Each Trusted Device reports its kind and when it was last active in an end-to-end encrypted
  Trusted Device Record (ADR 0079). The Trusted Devices list in the registration snapshot includes
  the device in hand, marked `current`, and gives each device its reported `kind` and `activeAt`.
  On iPhone and iPad, Account & Devices lists every Trusted Device with its kind's symbol, its name
  and "This iPhone" or "This iPad" with Current Device, "Last active …" with the exact time, or
  "Added …" with a neutral symbol until the device reports. VoiceOver reads each row as one element
  with Remove as its action. The Mac still lists only the devices it can remove (#2607).

### Patch Changes

- ebb70f1: On the Mac, closing a New Message window that Expand opened asks **Save this Draft?**. **Save Draft** reopens the Draft in the overlay of the Inbox window it came from and brings that window forward. If that window has closed, another Inbox window of the same Mail Profile is used, or a new one opens. When that overlay already holds another Draft, the app first asks **Save Other Draft and Return**. **Discard Draft** deletes the Draft and brings the Inbox window forward, and **Cancel** keeps the window open (#1671).
- e662cb5: On the Mac, a search that matches nothing shows the **No Results** empty state, naming the scope and the query, and the subtitle reads "No results · Travel" for the searched folder or mailbox, or "No results · All Mailboxes" for several; while the mail servers are searched, skeleton rows hold their answer's place and the subtitle names the mailboxes searched, as in "Searching All Mailboxes…" (#2346, part of #2090). A Unified Mailbox now reports `unlisted` while a mailbox is opening or a folder has listed nothing yet because its first listing is still to arrive or failed. `inboxUnlisted` says whether a mailbox has listed its Inbox yet.
- 6d7c277: The iPhone and iPad reader show a body that is still loading and one that cannot be shown as their frames draw them: on iPad **Downloading from Gmail…** above still placeholder lines, on iPhone a centred **Loading message…**, and on both a **Couldn’t load this message** banner with the reason and **Try Again** (#2395, part of #2091).
- 9054e1a: iPhone and iPad disable Send while the Draft cannot be sent as it is, and say why before Send is pressed (#2396, part of #2092).

  - **Add a recipient to send.** shows under To, or on one line above a docked iPad reply's From and Send; text that is not an address says it is not a complete address once its field is left. VoiceOver reads the reason with Send.
  - A sending mailbox that needs sign-in again shows the Authorization Needed banner under From, with **Sign In…**; the Sent folder, file and other sender problems show among the composer's notices.

- e6be4e9: iPhone Mock Mail Session builds offer the German test catalog as **Deutsch**, as Mac ones do; shipped builds never carry it. A recipient field's placeholder that does not fit beside Cc/Bcc now ends with an ellipsis instead of clipping (#2415, part of #2096).
- 98f27cb: iPhone says a Trusted Device removal in two sentences: “{name} loses access to your Unwired account and sync, and you save a new Recovery Key. Mail it already holds can’t be erased remotely.” iPad and Mac keep the full explanation (#2416, part of #2100).
- e1948d0: On iPhone and iPad, Settings › Blocked Senders that this device couldn’t read says **Couldn’t Load Blocked Senders** in the middle of the page, as the approved frames draw it, and **Try Again** reads them again; before, the page asked to leave it and open it again (#2420, part of #2100).
- d6a124c: On Mac the Outbox is a sidebar row after Sent while the window's Mail Profile has a message in it, instead of rows at the top of the Inbox column. Selecting it lists the messages under the heading Outbox with a subtitle counting those waiting and those not sent; when the last one leaves, the list returns to All Inboxes. VoiceOver hears where each message stands whichever list the window shows (#2421, part of #2101).
- 5246109: On iPhone and iPad, **New Label…** after a Gmail message's labels opens **Labels**: type a name, and **Create “Acme” inside “Clients”** creates the nested label in Gmail and applies it, while a name a label already has applies that label. A name another label has in a different case offers **Use “clients/acme”** or **Edit Name** instead of creating a duplicate (#2441, part of #1683).
- 1872d39: On the Mac, **New Label…** in a Gmail message's **Labels** menu opens the **Labels** popover in place of the name alert: type a name, and **Create “Acme” inside “Clients”** creates the nested label in Gmail and applies it, a listed label applies at once, and a name another label has in a different case offers **Use “clients/acme”** or **Edit Name** in a sheet. iPhone, iPad and Mac share the naming rules through `typedLabel` in `@private-email/mail-core/gmail-actions` (#2442, part of #1683).
- 16ef069: On the Mac, an invitation in an IMAP mailbox that can send offers **Accept**, **Maybe** and **Decline**: the response waits in the Outbox for the Undo Send Window with **Undo** and **View in Outbox**, then goes through the mailbox's own mail server, and the card names that server when it accepts, refuses or doesn't confirm the response. The Outbox shows the response in its own row with its meeting, choice and status, **Undo**, **Check Again** and **Open Invitation**, and no Edit. `invitationResponding` takes an IMAP mailbox's `server` from the new `imapServer`, and `outboxCopy` words an Invitation Response's status as a response (#2446, part of #1279).
- 3b19eb2: On iPhone and iPad, the Send menu (a long press on Send) offers **Send Now**, "No Undo": it sends through the same Outbox checks as Send but without the Undo Send Window, with no confirmation. While a file is still being added, Send Now is dimmed and says "Waiting for <file> to finish". The Outbox's `send` takes a third `delay` argument, the Undo Send Window in milliseconds, which Send Now sets to 0 (#2457, part of #1674).
- 44a7672: On Mac, iPhone and iPad, when storage refuses Undo for a waiting IMAP invitation response, the invitation card says **Couldn’t undo your response** and the Outbox row says _Couldn’t undo. Still waiting to send._, each with an amber warning triangle and **Try Again** in place of **Undo**. The notice clears once the response stops waiting (#2462).
- c416829: On iPhone and iPad, **Outdent** and **Indent** follow the list buttons in the Format panel and the format bar, and a hardware keyboard's Tab and Shift-Tab do the same inside a list. Lists nest three levels deep, each change is one Undo step, and sent mail nests the lists. The Semantic Message Document's list blocks gain an optional `indent` (1 or 2), `listIndentAt` and `indentList` change it, and `listNumbersOf` counts numbered items per level (#2465, part of #1679).
- 17eb728: On iPhone and iPad a downloaded attachment's context menu is titled with its file name and offers **Save to Files…**, which saves a copy through the system document picker. The reader then shows a toast naming the folder and the copy's file name, with **Show** to open it in Files; cancelling says nothing, and when nothing was saved the reader says so and offers **Save to Files…** again (#2469, part of #1681). The inbox store's `saveAttachmentCopy` resolves the saved copy, `'cancelled'` or `'failed'`.
- 768201e: On iPhone and iPad, touching and holding an inline image's row in the composer offers Small (320 px), Medium (640 px), Large (1024 px) and Original, with a checkmark at the current size, then Remove Image; VoiceOver offers the sizes as actions. A size applies to every use of the image in the body as one Undo step. mail-core adds `imageWidthOf` and `withImageWidth` (#2577, part of #1735).
- f7ca447: On iPhone and iPad, toasts are Liquid Glass capsules instead of deep graphite: 48pt tall with a 24pt radius, the symbol and message in the primary text color and the action in the accent ink in Light. On iPhone a message that does not fit one line wraps to a 64pt toast. The refused Undo or Edit toast shows the frames' shorter "Couldn’t return the message to Drafts." (on iPad with the subject); VoiceOver still hears the full sentence (#2591, part of #2104).
- b2ff343: On the Mac, **Edit Favorites…** in the Favorites header's menu, or Edit Favorites in the Command Palette, lets the sidebar show or hide each Favorites row and reorder them until **Done**; All Inboxes stays shown. The Profile's choice is kept in its Inbox preferences and synchronized through Private Sync, and each Unified Mailbox can be opened from the Command Palette (#2593, part of #2106). `createInboxPreferences` adds `favorites` and `setFavorites`; `favoriteRows`, `toggleFavorite`, `moveFavorite` and `sidebarCommands` are new.
- d0be5d8: On the Mac, the Send menu (a right click on Send) offers **Send Now**, "No Undo": it sends through the same Outbox checks as Send but without the Undo Send Window, with no confirmation. While a file is still being added, Send Now is dimmed and reads "Send Now — waiting for <file>" (#2594, part of #1674).
- d7bd630: On Mac, **Outdent** and **Indent** follow the list buttons in the composer's format bar, **Format › Increase Indent** (Command-]) and **Decrease Indent** (Command-[) do the same, and Tab and Shift-Tab do it inside a list. Lists nest three levels deep and each change is one Undo step (#2597, part of #1679).
- 811634a: On iPhone and iPad, **Edit** in Mailboxes, beside Account on iPhone and the sidebar toggle on iPad, lets Favorites show or hide each row and reorder them until **Done**; All Inboxes stays shown. The rows are the Profile's synchronized Inbox preference the Mac already edits, hiding the selected Unified Mailbox selects the first row still shown, and the Command Palette opens each Unified Mailbox, leaving a reader or composer that covers the list first, and, while the iPad sidebar shows, Edit Favorites (#2611, part of #2106). Edit also shows or hides each Mailbox Connection and its folders and reorders them: connections in the Profile's shared order, where a refused order says so, and each connection's visibility and folders in synchronized Inbox preference fields of their own (`showSection`, `changeFolders` and `sections`, which is undefined until read and after a failed read; `sectionShown`, `sectionFolders`, `folderRows`, `showFolder`, `moveFolder`, and `showFavorite`, so a tap stores the opposite of what its row showed even when another write lands first and leaves every other folder in its stored place, even one this device has yet to list, and a tap that changes nothing stored, as on a connection's Inbox or on All Inboxes, which stay shown, writes nothing, so another device's newer choice stands). A hidden connection leaves All Inboxes and its search, and posts no New Mail Notifications on any device, the Mac included, as each delivery pulls the preferences from Private Sync once the notification settings are read, then checks the Profile its connection is in in the same step that hands them to the host (`arrived` takes `settle` and `eligible(profile)`), so a hide or move counts for every delivery checked after this device stores it, and none posts while that pull fails, the Profile's record does not open, or another device's write overtakes every pass (`pulled`); until the preferences are read, and while a later read fails, none posts, even one already pending. Hiding the selected connection or folder selects All Inboxes. A drag scrolls Mailboxes near its edges once the row moves, and changes nothing when another device reorders the rows meanwhile: `arrangeMailboxes` takes the order it was made `from` and writes nothing when the stored order differs, and an arrangement made during foreground verification is stored once it finishes; a Favorites or folder move onto rows whose order this device stored after showing them writes nothing either, as a `changeFavorites` or `changeFolders` change that returns undefined writes nothing. After a relaunch, All Inboxes lists no account's mail, nor Mailboxes any account, and Edit, from its button or the Command Palette, is unavailable, until the preferences are read, and All Inboxes names no hidden account, not even one waiting for or needing sign-in, nor counts one in its Sync Status Capsule, its subtitle, Filters, loading state, search progress or answer, or pull to refresh, and an account's own Inbox is named as its scope; All Inboxes takes its loading state, readiness and row motion only from the accounts it shows, none of them hidden, so a row leaving as an account is hidden leaves at once; while the preferences are read it shows it is loading, and after a failed read (`unreadable`, for each account whose read failed) it says so with Try Again, which, like pull to refresh, reads them again, a pull while they are read or unreadable then synchronizing the accounts they show; with every account hidden, even one waiting for sign-in, it names itself, not the provider, and shows No Mail and search answers once the preferences are read, without waiting for any account to list; a drag whose account another device removes ends with it; search widened from a connection's Inbox to every Inbox answers once the preferences are read, which a pull there reads again; signed out, `sections` hides none. `sidebarCommands` takes `unified` as optional, as it takes `favorites`.
- 6a9034c: iPhone and iPad: the Save your Recovery Key step offers **Copy** and **Save to Files** under the key. Copy puts the key on this device's clipboard only, where it stays for two minutes; Save to Files hands a plain-text file with the key to the system's save panel and keeps no copy. Neither confirms the key (#2616).
- 1250d61: On the Mac, a downloaded received attachment's menu offers **Save As…**, which opens the system save panel on the reader's window. The reader then shows a toast naming the saved copy and its folder, with **Show in Finder**, or, when nothing was saved, **Couldn’t save to** the chosen folder beneath its header. Cancelling says nothing, and a result is dropped once the reader left the message or storage locked (#2625, part of #1681).
- 677485c: On iPad and iPhone, typing `/` at the start of a body block opens the Slash Command Menu with the Basic Blocks: Text, Heading 1 to 3, Bulleted List, Numbered List, Quote and Code Block. Typing filters them; a tap, Return or Tab sets the block and removes the typed command as one Undo step. An iPad hardware keyboard moves the highlight with Up and Down Arrow and closes the menu with Escape (#2656).
- 270175e: On iPad, the reader's More menu lists Move to Spam directly after Mark as Read or Unread and before Move to…, as the approved frame draws it. On iPhone and iPad, mail in Spam offers Not Spam there instead of Move to Inbox; Trash keeps Move to Inbox (#2662).
- ce6b413: On the Mac, once a received attachment is saved to Downloads with **Save As…**, its Profile remembers Downloads on this Mac and the attachment's menu offers **Save to Downloads**, which saves a copy there directly. A name already in Downloads asks to **Keep Both**, **Replace** or **Cancel** (#2664, the last slice of #1681).
- 8c26803: On iPad and iPhone, the Slash Command Menu lists Attach File… and Insert Image… under Insert, after the Basic Blocks. Typing filters both sections. Choosing one removes the typed command and opens the same picker as the format bar, which places an inserted image at the caret when it returns (#2668).
- ac45565: On the Mac, Settings gains a Mail group with **Reading**: Text Size follows macOS, and **Message zoom** zooms received formatted mail in the reader from 50% to 300%, kept on this Mac only. The message and Drafts don't change, and an open message keeps its selection as the zoom changes. Remote images further down a message taller than the reader now load as they come near on the Mac too (#2678, #2680).
- a0b02eb: On the Mac, Control-clicking an inline image's row in the composer opens an Image Size submenu: Small · 320 px, Medium · 640 px, Large · 1024 px and Original, with a checkmark at the current size, then Remove Image; VoiceOver offers the sizes as actions. A size applies to every use of the image in the body as one Undo step (#2696, part of #1735).
- aa9ba6e: Outlook.com and Microsoft 365 meeting invitations show the invitation card on Mac, iPhone and iPad, read from the message's MIME, and **Accept**, **Maybe** or **Decline** sends one reply through the owning Microsoft connection. **Check Again** finds an unconfirmed reply in Sent Items by its Message-ID, and the card names the provider Outlook.com or Microsoft 365 (#2703).
- 2ed2a21: An inline image's size menu now names the image's own size under Original: its width and height on iPhone and iPad, and its width on the Mac, read on the device with the row's thumbnail (#2729, part of #1735).
- 4fda2a6: Writing tools can now say when a rewrite needs clarification. A `needs-clarification` rejection from the native model reads as a text-free `{ kind: 'clarification' }` Draft assistance state for Rewrite, Expand Text, Shorten Text, Make More Friendly and Make More Neutral, and as `failed` for every other operation. On Mac, iPhone and iPad the composer shows the approved card: "Couldn’t rewrite this. Your Draft is unchanged — edit your original to make it clearer, then try again." It offers Try Again and Close and leaves the Draft and its Undo history unchanged. The native binding does not emit the code yet (#2776).
- 746507f: On the Mac, typing `/` first in a body block opens the Slash Command Menu with its Basic Blocks, each ending with its Markdown marker. Typing filters the rows, Up and Down move the highlight, Return, Tab or a click sets the caret's block as one edit that one Undo reverts, and Escape, a caret move or leaving the body closes the menu.
- 7def2c1: On iPhone and iPad, a file that wasn't added names why, or says "Wasn't added", and offers Try Again, which adds the same file again without a picker. An importing file reads "Importing… 64%" with a progress bar, and while it imports the reason above the body names it and VoiceOver reads it with Send (#2795).
- ea52abb: On the Mac, Settings › Reading has **Fit wide messages to the screen**, on by default and kept on this Mac. A received formatted message wider than the reader now shrinks to the reader's width at every Message zoom instead of scrolling sideways; turned off, it scrolls sideways as before (#2803, part of #1728).
- f14bf7b: On the Mac, More › Message Zoom… and View › Zoom In, Zoom Out and Actual Size zoom the open message alone until it closes, and Use … for All Messages keeps the level as Message zoom. The Command Palette offers the same Zoom In, Zoom Out and Actual Size (mail-core's `zoomCommands`) while the reader shows formatted mail. Show Inbox moves to Shift-Command-0 (#2808).
- 5f1fa3a: On iPhone and iPad, **Settings › Notifications** lists each Mail Profile with a **Badge and sound** switch. A Profile switched off adds nothing to the App Icon Badge, and its New Mail Notifications play no sound. Every switch starts on and stays on this device; while notifications are off, the group is hidden and the choices are kept (#2809, part of #1723).
- 1ff7a94: On the Mac, **Settings › Notifications** groups **Dock badge** and a new **New mail sound** pop-up under **On this Mac**, and lists each Mail Profile's **Badge and sound** switch. New mail sound offers **Default**, the Mac's alert sounds (such as Glass) and **None**; shown New Mail Notifications play the chosen sound. A Profile switched off adds nothing to the Dock badge and its notifications play no sound. The choices stay on this Mac; while notifications are off they stay, dimmed (#2811, part of #1723).
- eaa3ffc: On iPhone and iPad, **Settings › Notifications** offers a **New Mail Sound** pop-up under **App Icon Badge** with **Default** (the system notification sound) and **None**. It starts at **Default** and stays on this device. New Mail Notifications play the chosen sound, or none; while notifications are off, the choice stays, dimmed (#2812, part of #1723).
- 90c6a63: On the Mac, a message with a one-click unsubscribe offer shows an Unsubscribe banner naming its mailing list, and **Unsubscribe…** in the reader's More menu. **Unsubscribe…** asks first, naming the list and the receiving address, and only **Unsubscribe** sends the request, once. The banner then says the request was sent, dated, or that it failed or got no clear answer, with **Try Again**, which sends again without asking, and **Block Sender…**. A list the Mail Profile asked to leave in the 14 days before the message arrived shows as sent. A message whose only offer is `mailto:` shows neither yet (#2967). The theme gains `fillBanner`, the banner's opaque fill.
- 33508c9: On Mac, a message whose list unsubscribes by email offers Unsubscribe… too: it emails the request from the receiving mailbox through the Outbox, shows it waiting with the Undo Send toast, then sent and dated, refused or unknown, and says when the mailbox must sign in again or receives only. The Outbox keeps the request's Mail Profile and list and records a confirmed send through `unsubscribe.record` before the request leaves it; its Outbox row offers Undo and no Edit.
- 3c710f3: On the Mac, the body's @ also works in written text, where choosing a person replaces only the query with their given name, else display name, else address, and it lists people already in To, Cc or Bcc with their role, keeping that role and never adding them twice. `@private-email/mail-core` adds `bodySuggestionSections` and `recipientRole`, and `addBodyRecipient` takes the `name` it inserts in written text (#2976).
- f6e54e4: On iPhone and iPad, the Send Reminder choices end with Choose Date and Time…, which shows the system's calendar and time in the same sheet or popover. It starts at the Draft's reminder or Tomorrow Morning, refuses days before today and times that have passed, and Set Reminder stores the picked instant with the device's time zone.
- 67a8f0a: The Mac reminder menu offers Choose Date and Time… (#2980, part of #658). It opens a popover with AppKit's calendar and time field, starting at the Draft's reminder or tomorrow at 9:00; a time that has passed dims Set Reminder, and Set Reminder stores the chosen time with the Mac's time zone.
- 320d3e9: On iPhone and iPad, a message with a one-click unsubscribe offer shows an Unsubscribe banner naming its mailing list, and **Unsubscribe…** in the reader's More menu. **Unsubscribe…** asks first in a system alert, naming the list and the receiving address, and only **Unsubscribe** sends the request, once. The banner then says the request was sent, dated, or that it failed or got no clear answer, with **Try Again**, which sends again without asking, and **Block Sender…**. A list the Mail Profile asked to leave in the 14 days before the message arrived shows as sent. A message whose only offer is `mailto:` shows neither yet (#2985).

  The `registration-unsubscribe` Mock Mail Session lists three one-click newsletters, and mock builds answer a one-click request with the outcome its URL names.

- 4e72a1a: A due Send Reminder now posts a notification on the device that set it, at the Show Sender and Subject level of that device and with no actions; changing or removing the reminder, or sending or discarding its Draft, withdraws it. `createHost` returns `followReminderNotifications`, and the native host module declares `scheduleReminderNotifications` (#2990).
- e343f79: On the Mac, a file being added to a Draft reads **Importing…**, then its percentage with a progress bar as native code reads it, also after Try Again (#2992).
- 20dffd7: Forward opens its Draft at once on Mac, iPhone and iPad: each original file that isn't downloaded yet shows as importing while the Draft downloads it, and one that couldn't be downloaded is Not added with Try Again. The reader no longer shows Preparing to forward… (#3119). While a file downloads, saving a Draft and its recovery writes no longer wait for it, so text typed meanwhile survives the app closing.

  The `registration-forward` Mock Mail Session lists a message whose attachment downloads after 30 seconds, to show a forward's importing file in native captures.

- 0302409: Refresh dependencies to the latest compatible versions: Effect 4.1.5, Convex 1.51, jose 6.2.18, i18next 27.2 and react-i18next 18.0, parse5 8.1, the CSS parser 4.0.3 and Tiptap 3.34 in the Draft editor page. The Mac app moves to React Native macOS 0.83, with React Native 0.83.10 and React 19.2, and to WebView 14.0.1, the version iPhone and iPad use. In Effect 4.1 a request that waits for a lock can no longer take a free lock ahead of an earlier waiter, so a history backfill step in a Gmail, Microsoft or IMAP Inbox now steps aside for any Inbox request that is waiting, such as a synchronization, a change being sent or Discard Change, so a history read no longer delays them. Each tagged error class now carries a type brand, so another class with the same fields no longer type-checks as it.

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
- 52a62f7: Show when the Inbox was last brought up to date on iPad and Mac (#1444).

  - **Subtitle:** when the shown mailboxes are neither syncing nor offline, the iPad and Mac Inbox subtitle adds how long ago they were last brought up to date, such as `12 unread · Updated just now` or `Updated 5 minutes ago`. With several mailboxes shown, the oldest last update counts. iPhone's one-line subtitle leaves it out.
  - **Recorded per connection:** Gmail, Microsoft and IMAP connections save when their latest completed synchronization started with their encrypted cache, so the time survives relaunch and later failed attempts. Each successful synchronization saves the time, even when no mail changed.

- d952552: Respond to a single Gmail meeting invitation from the Mac reader (#1640).

  - **Card:** an opened Gmail message with a one-meeting `METHOD:REQUEST` calendar part shows the meeting above its body, with Accept, Maybe and Decline when it names the opened mailbox.
  - **Sending:** a chosen response is one iCalendar REPLY to the organizer in the invitation's thread, sent only on request and never repeated on its own after an unknown delivery.
  - **States:** sending, confirmed, refused, offline, sign-in, delivery unknown with Check Again and Respond Again…, another invited address, and invitations Unwired can't read.

- 6bc653c: When a Gmail meeting invitation names two or more addresses of the same Mail Profile, the Mac, iPhone and iPad readers list each of them under Invited and say which address this copy responds for. The response is still sent only from the opened mailbox.
- d2ce522: The Mac, iPhone and iPad readers show a weekly Gmail meeting series that ends on a date or after a number of meetings, with its meeting times and first and last dates, and one response answers the whole series. When the local weekday or times vary, the card names the first meeting instead of presenting its times as recurring.
- c9acd6e: The Mac, iPhone and iPad readers show a Gmail invitation to one meeting of a series with that meeting's date and a **One meeting in a series** line, and a response answers and is recorded for that meeting only.
- 2d0af86: The Mac, iPhone and iPad readers show an older revision of a Gmail invitation, after a newer one was answered, with an **Older version** badge and **There’s a newer version of this invitation**, and offer no response from it.
- 123f78c: An older revision of a Gmail invitation offers **Show Latest** on Mac, iPhone and iPad, which opens the message carrying the newest revision this device answered. A recorded response now keeps the message it answered; records saved before it have no **Show Latest**. A Gmail online search result that Gmail later deletes no longer stays available to the reader.
- f93ec59: Set, change and remove a Draft's Send Reminder from the Mac composer's Send menu (#2123, part of #658).

  - A right click on Send opens the Send menu; Remind Me to Send… opens the reminder menu from Send with This Evening (20:00, while still ahead) and Tomorrow Morning (9:00) in the Mac's time zone. Choosing one saves the Draft, keeps the composer open and stores the reminder.
  - The composer shows the Draft's reminder in a banner with Change and Remove Reminder, and Send or Discard removes it. A refused write is reported and changes nothing.
  - mail-core gains `reminderTimes`, `reminderDay` and `reminderCity`. Reminders still notify nobody and are not synchronized.

- e8772e0: Reply from a new-mail notification on the Mac: the Reply field names the receiving
  address, Send queues a threaded reply with only the typed text through the Outbox,
  and a Reply to <sender> notification offers Undo during the Undo Send Window. A
  message no longer listed keeps the text in Drafts and offers Open Draft. Outbox Undo
  can be limited to a message still in one state.
- 63559b4: Set, change and remove a Draft's Send Reminder from the iPhone and iPad composers' Send menu (#2136, part of #658).

  - A long press on Send opens its menu; Remind Me to Send… offers This Evening (18:00, while still ahead), Tomorrow Morning (8:00), Next Week (Monday 8:00) and, on iPhone from Sunday to Thursday, This Weekend (Saturday 9:00) in the device's time zone, from mail-core's new `mobileReminderTimes`, in a sheet on iPhone and a popover from Send on iPad. Choosing one saves the Draft, keeps the composer open and stores the reminder.
  - The composer shows the Draft's reminder in a banner with Change and Remove Reminder, and Send, Discard or an empty Close removes it. A refused write is reported and changes nothing.

- 03229b6: Block and unblock a sender on the Mac (#2141, part of #655).

  - A reader's sender menu gains Block Sender…, which confirms in a sheet and blocks the sender's exact address for the window's Mail Profile.
  - Settings › Blocked Senders lists each Profile's Blocked Senders, newest first, with the date blocked and how many arrivals this device moved to Trash, and − unblocks the selected one.
  - `createBlockedSenders` gains `subscribe`, and each Blocked Sender keeps a `moved` count since it was blocked, and `screen` takes the connection with whether it can move to Trash now.

- af0289b: Mac Settings › Appearance chooses Light, Dark or System for every window (#2153, part of #1727). The choice stays on this Mac and applies from launch.
- b625cbd: Block and unblock a sender on iPhone and iPad (#2166, part of #655).

  - The reader's sender menu gains Block Sender…, which confirms in the system alert and blocks the sender's exact address for the reader's Mail Profile.
  - Settings › Blocked Senders lists each Profile's Blocked Senders, newest first, with the date blocked and how many arrivals this device moved to Trash; swipe or Edit unblocks one.

- ed4f8c1: iPhone and iPad Settings › Appearance chooses Light, Dark or System (#2168, part of #1727). The choice stays on this device and applies from launch.
- ad88bc7: iPhone and iPad Settings › Appearance chooses each Mail Profile's List density, Comfortable or Compact (#2202, part of #1727).

  - Compact lets a Thread-list row's subject wrap and keeps one preview line at every text size.
  - `createInboxPreferences` keeps each Profile's Inbox preferences in an encrypted device document and synchronizes them as one sealed `profile-inbox-preferences.` record per Profile, merging each preference's latest choice; native code adds `openInboxPreferences`, `commitInboxPreferences`, `pullInboxPreferences` and `pushInboxPreferences`.

- 6e8cfb3: Mac Settings › Appearance chooses how many preview lines Inbox rows show: None, 1, 2 or 3 (#2222, part of #1727).

  - The choice is each Mail Profile's synchronized preview length; the Mac's Settings window sets it for every Profile.
  - Inbox rows follow macOS's sidebar icon size, read at launch.
  - `createInboxPreferences` adds `previewLines` and `setPreviewLines`.

- 6d508f9: The Mac composer disables Send while the Draft cannot be sent as it is, and says why before anything is pressed (#2350, part of #2092).

  - No recipient shows "Add a recipient to send." under To; text left in To, Cc or Bcc that is not an address shows a warning and "“…” is not a complete address. Correct it to send." under that field, as the approved frame draws it.
  - A non-ASCII address, an IMAP mailbox without one Sent folder and a file still importing or failed show their sentence above the body without an announcement. The Command Palette's Send and the Send menu's Send are unavailable too; Remind Me to Send… stays available.
  - `Outbox` gains `refusal`, the check Send makes before reading files.

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

- 0c85d0a: Notify privately for newly arrived Gmail Inbox mail on iPhone, iPad and Mac (#619). Settings › Notifications shows this device's notification permission, an off-by-default choice to show sender and subject, and a switch for each Gmail mailbox that synchronizes end-to-end encrypted to every Trusted Device. Only unread mail Gmail reports as newly added to the Inbox notifies, once, after it is saved; listings, backfill and moved mail never do. Tapping a notification opens its message.

  Unreadable synchronized policies turn notifications off locally and cannot be overwritten. Refused changes show the latest learned policy and feedback on the mailbox's row; concurrent changes are handled without logging a registration failure.

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
- 0c7e666: List, download, open and share received attachments of IMAP mail on iPhone, iPad and Mac, with the same rows, limits and protected local storage as Gmail. Downloads read the message source again at its folder's UIDVALIDITY, and a folder synchronization that records a new UIDVALIDITY deletes saved attachments of the folder's earlier messages, including downloads in flight.

  Gmail, Microsoft and IMAP Inboxes now share one attachment download implementation.

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
- 64aac67: Choose the iPhone and iPad interface language from a native menu picker in Settings' Language, with an explanation of System Default, and on the Sign In page. The Inbox list footer and the setup page no longer show the language options.
- 4b314a8: On-device summaries and rewrites ask for the language of the message or authored text (#1164). When it confidently identifies that language, the native binding names it to Apple's model and rejects an unsupported language or a confidently detected output language switch as `unsupported-language`. The preview explains the limitation and mail and Drafts stay unchanged. Rewrite instructions forbid added subject lines, greetings and signatures. The assistance qualification corpus is now version 4, with heuristic checks for language switches and added letter framing. Generated text still needs human review.
- 6bb7771: Choose the Mac interface language from a native pop-up in Settings' Language and at the end of the sign-in page. VoiceOver reads it as a pop-up button with its current choice. The Inbox list footer and the setup page no longer show the language options, and Settings' Language uses the translate symbol.
- a35a049: Name reader controls without repeating their role. A blocked image without a description
  shows and reads "Image not loaded" in the app's language instead of showing "Image" under an
  image label, kept to one line within a small sender-sized placeholder, and each message link's keyboard control is named by the link's text or
  destination instead of "Open link: …" and is underlined like other links.
- 2fba864: Replace the Mac reader's Gmail Labels panel with native menus: the folder button opens the Move menu for Gmail too, and a new More menu offers Mark as Read or Unread, Move to and, for Gmail, a Labels submenu that checks each applied label and adds or removes the one chosen.
- 5e27303: Add New Label… to the Mac reader's Gmail Labels submenu: a native alert asks for a name, then the label is created in Gmail and applied to the message. Gmail label creation is a new native write that receives only the label's name, and menu submenus can now group their items.
- dee8006: Expand in a Mac window's composer saves the Draft and moves it into its own New
  Message window, closing the overlay. Closing that window or quitting asks its
  composer first, including in the regular editor. A refused save or unfinished
  recipient keeps the window open and cancels Quit. The window closes itself once
  no Inbox can open or its Product Account changes.
- d65b96e: Settings explains a remote-content choice it couldn't save: the pop-up keeps the saved choice and a warning under the row, announced to VoiceOver, says what is still set until the next change. Clear Saved Remote Content shows Clearing… with an activity indicator, and Check Deletion Status shows Checking deletion status… with an indicator, each disabled while it runs, on Mac, iPhone and iPad.
- b7fc9a4: Removing a mailbox in Settings keeps its confirmation open while the removal runs: Remove shows Removing… with an activity indicator, and Remove and Cancel are disabled. If the mailbox could not be removed, the confirmation stays with a warning, announced to VoiceOver, that says it is still connected and, when this Mac, iPhone or iPad is offline, says so; Remove and Cancel are enabled again. A removal that applied before its reply failed closes as removed. If its outcome cannot be read back, the confirmation stays with an uncertainty warning and allows retry without claiming the mailbox is still connected.
- e122954: Settings › Mail Profiles shows a queued change while it runs. The control that
  started it shows an activity indicator: a move to Family reads **Moving to Family…** on the Mac, and the indicator replaces the pop-up on iPad and iPhone.
  Add Mail Profile…, the Name field, the mailbox pop-ups and Remove Mail Profile…
  are disabled until the change completes or fails. Disabled Settings rows now dim
  to 40%.
- 1c52450: While a Gmail connection's history is still downloading, its All Mail subtitle shows how much has downloaded, such as "41,210 of 86,400 downloaded", and All Mail ends with a "Downloading older mail…" row that names the month the list has reached instead of the note that older mail stays in Gmail.
- 85bbda1: Show the Sync Status Capsule above the iPhone and iPad Inbox bar: it counts
  accounts still updating, measures All Mail's history download, and replaces
  per-mailbox "could not be reached" notices with one attention summary and
  Try Again for the unreachable mailboxes. A Gmail history download paused by a
  failed read now reports `paused` and asks for Try Again instead of showing progress.
  Authorization failures remain in Attention alongside their access-repair notices,
  including when a refresh interrupts an unfinished history download.
- a787e87: On iPhone and iPad, tapping the Sync Status Capsule now opens **Sync Status**: each
  shown connection's provider and address, what it is doing, its history download's
  progress, and its own **Try Again** or authorization action when it needs attention,
  with when the shown mailboxes were last up to date. iPhone shows it in a
  medium-detent sheet with **Done**, iPad in a popover on the capsule.
- 1a7cb66: Show the Sync Status Capsule above the Mac Inbox search bar: it counts accounts
  still updating, measures All Mail's history download, and replaces per-mailbox
  "could not be reached" notices with one attention summary and Try Again. Clicking
  it opens a Sync Status popover listing each connection's state, history progress
  and its own Try Again, with when the shown mailboxes were last updated. A new
  View › Refresh (⌘R) menu command synchronizes the key window's Inbox.
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
- b956ddf: List the open Draft's Send, Attach File…, Add Cc and Bcc and Discard Draft
  commands in the Mac Command Palette, under a Draft section named for its subject.
  A New Message window's palette no longer lists the disabled Selected Message
  commands.
- d0de90a: Mac Settings › Mail Profiles chooses a Profile's Color and Icon from system
  pop-ups after its name, and lists each Profile with its styled monogram: a
  circle in its Color with its Icon or first letter in white. The Primary Profile
  shows Graphite and First Letter. Shared mail-core adds the Profile Color tokens
  (`profilePalette`), the ordered `profileColors` and `profileIcons` with each
  Icon's SF Symbol, and a `restyle` refusal. Native pop-up menu items accept a
  `symbolColor`.
- e29e359: Show **Checking…** with an activity indicator on each file of a Mac Draft while
  Send checks its bytes. A checked file returns to its size; the first file that
  does not verify shows why, such as **Damaged on this device**, and nothing sends
  until Send is pressed again. VoiceOver hears **Checking attachments** once.
  `outbox.send` accepts an optional `report` callback that receives each step of
  the file check as a `SendCheck`.
- 2cdecde: Check Mac Writing tools results for the details they change. Before a rewrite
  is applied, the review panel compares links (including where linked words go),
  email addresses, amounts, numbers, dates, times and quotes with the original,
  lists each changed, uncertain, removed or added detail beside the original value and the
  kept ones, and offers **Use rewrite with changes** instead of Replace text when
  anything differs, with Keep original as the Return-key default. Every result notes that the checks compare details only. The
  assistance core exports `checkDetails`, and the semantic document exports
  `selectedLinks`.
- bc6c49e: Leave an IMAP connection out of All Mail, with a notice, until its server marks one Junk and one Trash folder, so All Mail no longer lists its Spam and Trash.
- ed443c8: On iPhone and iPad, the Inbox of a Mail Profile that owns no mailbox is subtitled
  "No mailboxes" instead of Gmail and its status, and shows No Mailboxes with
  Manage Mail Profiles…, which opens Settings › Mail Profiles.
- b7fa145: Check iPhone and iPad Writing tools results for the details they change. The
  review panel lists each changed, uncertain, removed or added link, email
  address, amount, number, date, time or quote beside the original (as a table on
  iPad, one line per change on iPhone) with the kept details, and offers **Use
  rewrite with changes** instead of Replace text when anything differs, with Keep
  original as the accent button. Every result notes that the checks compare
  details only.
- 611e189: On iPhone and iPad, an IMAP connection left out of All Mail because its server marks no Spam or Trash folder offers Choose Folders… in its notice, a sheet for choosing those folders by name. A ready IMAP Inbox state now reports the Spam and Trash folders its server marks itself as `marked`. A chosen folder no longer takes a role the server marks on several folders, so none of those folders loses it. Move to Inbox is offered from every folder the server marks as Spam or Trash, even when it marks several.
- 461ba87: On the Mac, an IMAP connection left out of All Mail because its server marks no Spam or Trash folder offers Choose Folders… in its notice, an AppKit sheet for choosing those folders by name with the same rules as iPhone and iPad. `@private-email/mail-core/mailboxes` now exports the shared folder choice model (`folderChoice`, `startingPicks`, `ambiguousFolders`) that both clients render. When the server marks only one of the two folders, the Mac and iPad sheets are titled "Choose a Spam Folder" or "Choose a Trash Folder", as the frames show; iPhone keeps "Spam Folder" or "Trash Folder".
- da46f67: On iPhone and iPad, Settings › Email Accounts lists each IMAP connection whose server leaves Spam or Trash unmarked under Spam and Trash Folders, warning that it is not in All Mail until both are chosen and naming the chosen folders afterwards; Choose Folders… or Change… opens the same folder sheet as the All Mail notice. `@private-email/mail-core/mailboxes` now exports `folderSummary` for that row.
- 8dd21c4: Add the Templates control to the Mac composer's format bar: insert one of the Draft's Mail Profile's templates as one Undo step, or save the Draft's subject and body as a new template.
- 5bd4eef: Add the Templates control to the iPhone and iPad composers: insert one of the Draft's Mail Profile's templates as one Undo step, or save the Draft's subject and body as a new template.
- 90ce1f1: Add Settings › Signatures to the Mac app: give each Sending Identity a formatted signature, stored and synchronized through Product Sync, or clear it. A signature chosen during foreground verification is stored once verification finishes.
- 4fce0f5: iPhone's Approve this device step waits for approval by itself: under the code, "Waiting for approval…" replaces the Check for approval button, and the device checks every 10 seconds while the step is on screen, without showing progress. A check that cannot finish, such as offline, leaves the step as it was. An Apple sign-in from before launch cannot check silently, so that step keeps Check for approval. "Use Recovery Key Instead", a text button, opens the Recovery Key as its own step, and "Wait for Approval Instead" returns. The registration store adds `checkForApproval`, and a Pending Device's status reports `approvalSignIn` when its check needs an interactive sign-in (#2066).
- ea1498c: iPad Settings returns to mail with a 44pt glass Back button at the top of its sidebar, named "Back to Mail", in place of the Close Settings `xmark`. Before sign-in the same button returns to Welcome in place of the "Back to Welcome" sidebar row (#2067).
- 11edb4c: The iPhone Inbox heading says "All read" when nothing is unread, as its frames draw it; iPad and Mac keep "No unread messages" (#2068).
- 9ac5048: Say on Mac, iPhone and iPad that a receive-only IMAP mailbox can't respond to a meeting invitation, with Mailbox Settings… to set up sending (#2114, part of #1279). Nothing is sent from another address.
- 20ba841: Mac menu shortcuts follow Mac conventions (#2174, part of #1993): File › New Message (Command-N) starts a Draft as the New Message button does, File › New Window moves to Option-Command-N, and View › Commands… moves to Command-K, which the command bar's key cap shows.
- 9de3fc7: The Mac Other IMAP Account form fills in the servers, ports, security and user name for an address at a catalogued provider (iCloud Mail, Fastmail, Yahoo, AOL, GMX, WEB.DE, mail.com and Seznam) and says so, until the person changes a server setting (#2176, part of #2004).
- dfd883c: Mac Edit › Undo (Command-Z) undoes the key Inbox window's last Archive, Trash or Move, as its Undo notice does (#2188, part of #1993). It stays unavailable while a text field has focus, so the composer body keeps its own Command-Z.
- 6e13ab3: Mac, iPad and iPhone say "your Unwired account" where they said "Product Account", and **Unwired Account** where it is a name: the Settings row and **Delete Unwired Account** (#2211, part of #2006). `docs/localization.md` records the approved interface word list and error rule.
- 2599daf: Mac, iPad and iPhone say "Profile" where they said "Mail Profile": Settings › **Profiles**, **New Profile…**, **Manage Profiles…**, the Profile Switcher's VoiceOver label and the Profile messages (#2227, part of #2006).
- 49c2c3a: Mac, iPad and iPhone say "account" where they said "Mailbox Connection" (Settings › Email Accounts › **Accounts**, **Add Account…**) and "access" where they called a mailbox sign-in an "authorization" (#2229, part of #2006).
- 40a45a6: Mac, iPad and iPhone explain a Mail Profile change that did not complete: a move or removal that fails because the device is offline says so, and any other failure asks the person to check the Profile, its name or its mailboxes before trying again, instead of only "could not … Try again" (#2238, part of #2006).
- e407c5a: Mac, iPad and iPhone explain a Blocked Senders change that did not complete: a failed block says it was not saved on this device and that new mail from the address still arrives as usual, a failed unblock says the sender is still blocked, and a list that cannot be read says how to read it again, instead of only "couldn’t … Try again" (#2241, part of #2006).
- 49553ad: Mac, iPad and iPhone say that a refused Notifications or Signatures change left the account's setting or signature unchanged and ask to check the connection and try again, instead of only "could not be changed. Try again later" (#2244, part of #2006).
- 1de6c21: Mac, iPad and iPhone explain a Send Reminder change that did not complete: a failed reminder says the new reminder was not saved on this device and to choose Remind Me to Send again, and a failed removal says the reminder is still set and to choose Remove Reminder again, instead of only "could not … Try again" (#2249, part of #2006).
- e71fdfb: Mac, iPad and iPhone explain a composer Discard or Send that storage refused: a refused Discard says the Draft wasn’t discarded and stays open, and to choose Try again or keep editing, and a refused Send says the message wasn’t sent, that it stays open, and to choose Send again, instead of only "could not … Try again" (#2252, part of #2006).
- 834fea8: Mac, iPad and iPhone use one name per action: Delete instead of Move to Trash or Delete Message, Move to… instead of Move Message, Move to Spam instead of Report Spam, and Try Again instead of Try again, Retry, Retry change, Retry deletion, Search mail servers again or Try saving assistance choice again; VoiceOver names retry buttons “Try Again to …”. All Mail's note says Spam instead of Junk, a disabled Command Palette command asks to select a Thread instead of a conversation, and the Sign In heading reads "Sign in to Unwired Mail" (#2257, part of #2083).
- ced407b: On Mac, iPad and iPhone the On device marker heads a summary, translation or Draft assistance result as "<Kind> · On device" (Summary · On device, Translation into English · On device, Shorten Text · On device) instead of a sentence; the sentence saying it was made on this device, may be inaccurate and is not saved follows the result as secondary text (#2259, part of #2083).
- 31685f4: Menu items and buttons on Mac, iPad and iPhone read in Title Case (Mark as Read, Load Images, Keep Original, Delete Permanently), and the unified mailboxes read All Inboxes and All Mailboxes (#2260, part of #2083).
- fb1f986: Mac, iPad and iPhone explain two Settings actions that did not complete: a failed language change says the language wasn’t changed and to choose it again, and a failed Clear Remote Content says some remote content may still be saved on this device, that mail isn’t affected, and to try clearing again, instead of only "could not … Try again" (#2262, part of #2006).
- f1e4c88: Mac, iPad and iPhone offer the provider's star only from the Command Palette, as Star and Remove star: the Mac reader toolbar, the iPad and iPhone More menu and Reply sheet, the row and reader context menus and VoiceOver's row actions no longer show it, and rows no longer carry a flag or say "Flagged". The folder chooser names a virtual `\Flagged` folder's role Starred (#2265, part of #2084).
- 35cd0c5: Mac, iPad and iPhone explain two reader actions that did not complete: a failed reply or forward says it didn’t open and to choose Reply or Forward again, and a failed Attach to New Message says the new message didn’t open and to choose Attach to New Message again, instead of only "could not … Try again" (#2269, part of #2006).
- ea2f7e2: Type @ in an otherwise empty Mac composer body to open Recipient Suggestions
  under it. Choosing a person adds them to To and replaces the query with a
  greeting, an empty paragraph and the caret, as one undoable edit. Suggestions
  come from recent mail of the Draft's Mail Profile and Apple Contacts the app can
  already read, without asking for Contacts access.
- a3f7570: Mac, iPad and iPhone explain two Settings › Mail Assistance errors: a failed save says the change wasn’t saved on this device and to choose Try Again, and a failed availability check says it didn’t finish and to choose Check Apple Intelligence Availability again, instead of only "could not … Try again" (#2275, part of #2006).
- 0e752cc: On the Mac, Pin and Unpin a message's Thread from the reader toolbar, the row and reader context menus, VoiceOver's row actions and the Command Palette; every row of a pinned Thread shows a pin and VoiceOver says Pinned. Pins stay on this device and never change a provider flag or star. mail-core adds `pinnedThread`, `subscribe` on the Pins store and the `pin` and `unpin` commands (#2280, part of #2084).
- ee5b308: Mac, iPad and iPhone explain a template that wasn’t saved: the "Template not saved" alert now says the message is unchanged and to choose New Template from This Message… to try again, instead of only "could not … Try again" (#2287, part of #2006).
- 685f0d7: Mac, iPad and iPhone explain an account removal they couldn’t check: Email Accounts now says the account may already be removed and to choose Remove again to finish, instead of only "Couldn’t confirm … Try again" (#2290, part of #2006).
- bd5e9c4: Mac, iPad and iPhone explain a Google or Apple sign-in link that did not finish: offline, the message says the device is offline and to choose Link … Sign-In again once it's online; any other failure says linking didn't finish and names the same button, instead of "could not be linked … Try again". Neither claims the Unwired account is unchanged, since a link can commit while its reply is lost (#2293, part of #2006).
- c478fa5: Mac, iPad and iPhone explain a Recovery Key confirmation that didn’t finish: the Recovery Key card now says confirming didn’t finish and to choose Confirm Recovery Key to try again, instead of only "could not be confirmed. Try again" (#2295, part of #2006).
- cd7b3d5: Mac, iPad and iPhone explain a new-device approval that didn’t finish: after **Approve Device** fails, the card now says approving the new device didn’t finish and to choose Approve Device to try again, and after **Decline** fails it says declining didn’t finish and to choose Decline, instead of "The device could not be approved. Try again." for both. `EnrollmentFailure` gains `decline-failed` (#2297, part of #2006).
- 2a0d6e7: Mac, iPad and iPhone explain a Trusted Device removal step that didn’t finish: Trusted Devices now says preparing the removal, removing the device or cancelling the removal didn’t finish, and names **Remove…**, **Remove {name}** or **Cancel** to try again, instead of "The device could not be removed. Try again." for all three. `RevocationFailure` gains `prepare-failed` and `cancel-failed`, and `revocationNotice()` takes the failure instead of a boolean (#2299, part of #2006).
- 9301b0a: Mac, iPad and iPhone explain a mail server search that didn’t finish for a reason the app can’t name: the message under From mail servers now says saved mail is still shown and to choose Try Again to search again, instead of only "The search did not finish. Try again." (#2301, part of #2006).
- 4956d41: Mac, iPad and iPhone explain an on-device message summary that didn’t finish for a reason the app can’t name: the reader now says the summary didn’t finish and to choose Try Again to summarize the message again, instead of only "The summary could not be created." (#2303, part of #2006).
- 7d63e3d: Mac, iPad and iPhone explain an on-device translation that didn’t finish for a reason the app can’t name: the translation panel now says the translation didn’t finish and to choose Try Again to translate again, instead of only "The translation could not be created." (#2305, part of #2006).
- ed25cbe: Mac, iPad and iPhone explain a Writing tools result that didn’t finish for a reason the app can’t name: the Writing tools panel now says the suggestion didn’t finish, that your text is unchanged, and to choose Try Again to get writing help, instead of only "The suggestion could not be created." When a long reply leaves no room for the quoted message, Suggest Reply now says so and suggests shortening the reply, instead of the same failure message without a Try Again button (#2307, #2308, part of #2006).
- 4ea2360: Mac, iPad and iPhone explain a message that didn’t open for a reason the app can’t name: the reader now says the message didn’t open, that saved mail has been kept, and to choose Try Again to open it again, instead of only "This message could not be opened." (#2310, part of #2006).
- 8e78f00: Mac, iPad and iPhone explain Drafts that didn’t open for a reason the app can’t name: the Inbox and the reader now say the Drafts didn’t open, that they have been kept, and to choose Try Again to open them again, instead of only "Drafts could not be opened. They have been kept." (#2312, part of #2006).
- 77c6958: Mac, iPad and iPhone explain a Private Cloud turn-on that wasn’t saved: Settings › Mail Assistance now says Private Cloud wasn’t turned on, that the change wasn’t saved on this device, and to choose Try Again to turn it on, instead of only "Couldn’t turn on Private Cloud. It’s still off." (#2314, part of #2006).
- dcf3dc0: Mac, iPad and iPhone explain an Outbox message that Undo or Edit couldn’t return to Drafts: the toast now says the message is still in the Outbox and to choose Try Again to return it, instead of only "Couldn’t return … to Drafts." (#2316, part of #2006).
- d80cbe8: Mac, iPad and iPhone explain a received attachment that didn’t download for a reason the app can’t name: its row in the reader now says the attachment didn’t download and to choose Try Again to download it, instead of "This attachment could not be saved on this device." (#2318, part of #2006).
- 585ad82: Mac, iPad and iPhone explain a translation language list the device couldn’t give: Translate now says the languages didn’t load and to choose Try Again to load them again, instead of only "Translation languages couldn’t be loaded." (#2321, part of #2006).
- d2af682: Mac, iPad and iPhone explain a mailbox whose saved mail can’t be shown for a reason the app can’t name: the Inbox notice and the reader now say the mail saved on this device can’t be shown, that it has been kept, and to choose Try Again to show it again, and its Sync Status row points to Try Again in the message list, instead of "Private storage could not be opened or saved. Your stored data has been kept." (#2324, part of #2006).
- 0cb8504: Mac, iPad and iPhone say "sync" where they said "Private Sync" (Settings › Account › **Sync is on**) and "your devices" where a sentence said "trusted devices"; the Settings title **Trusted Devices** stays (#2327, part of #2006).
- b62b0fd: The Mac offers each unsaved message the previous run kept (#2329, part of #1989).

  - Once the Drafts open after a relaunch, an Inbox window asks **Recover unsaved message?** for each composer recovery record the previous run left. **Restore** opens the composer on the recovered version, which Close then asks to save; **Discard** removes the record unless another composer has the Draft open, and keeps the stored Draft as it was. Records this run writes are never offered.
  - `@private-email/mail-core/drafts` exports `sameContent`, so a client can tell whether a composer recovery record changed since it was read.
  - `recovered()` leaves out every Draft the store journaled or forgot this run, so it returns only what an earlier run left, whatever order storage takes the calls in.

- 7243117: The Mac reader shows **Downloading message…** with placeholder lines while a body opens, and a banner with the reason and **Try Again** when it cannot; the download sentences say "this Mac" (#2348, part of #2091).
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

- c70cb72: Add Cut and Paste to the Mac Edit menu, so Command-X and Command-V work in
  search, composer and other text fields, including pasting files into the
  composer body. Escape now closes the Mac Command Palette, or leaves its folder
  picker, as documented.
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
- a59ebbb: Drafts and Mail Assistance follow the Mail Profile that owns their connection. A Draft's
  Rewrite, Suggest reply and Translate use that Profile's consent, and a request is retired
  whenever the connection moves to another Profile. Settings offers one Mail Assistance
  switch per Profile; with only the Default Profile it is unchanged. Each window lists only
  its own Profile's Drafts and Outbox. Moving a connection keeps its Drafts, the queued
  message and its delivery claim.
- 3d62e75: On iPhone, the Inbox shows Back to Mailboxes and its title and status line in one header row instead of below an empty navigation bar, and the Inbox surface fills the status bar and home indicator areas.
- 43b0b57: On iPhone, Reply in the reader grows a floating glass sheet out of the button (#969). It shows the sender's initials, name and message preview beside a Close button, then Reply, Reply All, Forward and Archive tiles and the Thread's other organizing actions in grouped rows, beside the toolbar's More, and shrinks back toward the button when closed. Reader menu panels and the composer's pop-up menus now ease in from their control and fade out on iPhone, iPad and Mac, and Folders on iPhone opens a Move picker that grows out of the button the same way: the mailbox's address, the message's sender and subject, folders with their role symbols (the current one unavailable) and a search field at the bottom. With Reduce Motion, menus and sheets only fade.

  Move search keeps its results visible in landscape with the software keyboard open.

- a426f0a: Add installation-local, opt-in error reporting with safe exception details and bounded breadcrumbs, consent revocation, and verified remote deletion. Native crash collection remains disabled pending platform qualification.
- ffb5ae2: Mac windows follow more of the Figma frames. Welcome lists the Mail Profiles benefit
  with the frame's rhythm and a 36pt Continue; Sign In keeps the frame's form position.
  The sidebar names Settings at its foot and hides at 900pt, so a narrow reader keeps
  its toolbar on one row. Toolbar, Command and Settings symbols use their compact
  sizes, date dividers are regular weight, and the Command and Search inputs show one
  focus ring. The composer keeps its fields directly above From and Send, centres
  them with their labels, shows From inside its pop-up and Aa in Text Style. Delete
  Product Account is a full Settings row, Language an inline pop-up, and the Mail
  Assistance On device marker a compact lock.

  Glass controls, sidebars and the Command Palette show the frames' dark 0.5pt rim and
  edge highlights, and the Settings sidebar casts its shadow over the page. The Command
  Palette's glass lets the reader show through, blurred, under the frames' menu shadow. Push buttons are
  6pt rounded rectangles, Settings row values and Text Style are borderless pop-ups, and
  a narrow reader moves the date beneath the sender instead of squeezing it. Welcome's
  lede and benefit symbols and labels, the sidebar's symbols, the Google button's outline and the Settings
  page's top spacing follow the frames.

- 23c0080: Expose a localized Collapsed value on Mac sidebar section headers so assistive technology can identify their state after closing them.
- 2fed635: Choose a Mac translation language from native menus. The reader's **Translate**
  pull-down lists the device's languages and becomes a pop-up naming the target
  while a translation shows, with **Show Original** to forget it. In a Draft,
  Writing tools › **Translate To** (or the toolbar's **Translate** menu) lists the
  same languages and opens the review panel for the chosen one. VoiceOver reads each
  language as a menu item with its checked state instead of an unknown-role control.
- 3d8b483: Add a locally packaged plain-paragraph Tiptap Draft editor for the isolated registration-draft-editor evaluation scenario, saving through the existing Draft store. Production and other scenarios retain the current composer.
