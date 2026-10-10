# @private-email/mobile

## 0.2.0

### Minor Changes

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

- 3beb5f5: Keep Gmail fresh across app lifecycles. On Mac, synchronization continues every five minutes after the last window closes and stops on Quit, with no helper process. On iPhone and iPad, a five-minute fallback poll runs while active, a background task synchronizes during the refresh opportunities iOS grants, and becoming active always catches up. Each run verifies registration and resumes from each mailbox's committed checkpoint. A shared wake-hint handler reads only a hint's opaque route and synchronizes only that mailbox. It never keeps Gmail's history ID or address, and ignores unknown or removed routes.
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

- 043d25c: Prepare both native clients for translated interface text. All interface copy, including registration, private sync, search, organizing, the reader, attachments and the Draft composer, now comes from one shared English catalog with per-key English fallback. The Language control under the Inbox and on the account page offers System default or a saved, device-local override. Dates and file sizes follow the device's regional format, including its calendar, numbering system and 12/24-hour preference, and Mac menus and window titles use the same catalog before JavaScript starts.
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

- dfc1f46: Preserve the image type of selected extensionless Draft files when system metadata leaves it unknown.
- d4bc7ee: Fix Google and Apple sign-in linking rejecting fresh identities when Convex omits the reserved JWT issue-time claim. Validate freshness from the gateway-authenticated bearer token in HTTP actions, retain internal ownership transactions, and explain that the current provider is verified before the provider being linked. Rebuild the native hosts with the matching backend deployment.

  Load local host configuration for Mac native builds, use the active Ruby gem executables, and generate automatically signed Apple Development projects. Preserve Google SDK diagnostics in the private native log.

- 262ac82: Keep registration and the mailbox usable when this device's Product Sync keys
  cannot be read. Restore, sign-in and Gmail authorization now report Product Sync
  as unavailable instead of failing and recording a mailbox failure, keep the
  unreadable keys unchanged, and log Product Sync errors by domain and code only.
- 6a839f1: Never overwrite a Product Sync mailbox descriptor this device cannot open. A
  record with a newer schema, a key epoch this device lacks or failed
  authentication is left unchanged and not shown; only a missing descriptor or a
  readable, different one is replaced.
- 15988d9: Preserve private Inbox storage and report locked storage while iOS protected data is unavailable.
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
- 15988d9: Update Expo compatibility patches for the mobile app.
- 611c8d3: Add isolated deterministic Mock Mail Session providers and native runners for the open, mark-read and encrypted relaunch journey. Keep scenario selection and cleanup outside the apps and exclude test providers from ordinary bundles.
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
- Updated dependencies [3beb5f5]
- Updated dependencies [3afd931]
- Updated dependencies [a39391a]
- Updated dependencies [0668ad3]
- Updated dependencies [0668ad3]
- Updated dependencies [043d25c]
- Updated dependencies [77d3937]
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
- Updated dependencies [dfab40f]
- Updated dependencies [262ac82]
- Updated dependencies [7c38123]
- Updated dependencies [819d141]
- Updated dependencies [30b173c]
- Updated dependencies [b45a92b]
- Updated dependencies [30b173c]
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
- Updated dependencies [34651eb]
- Updated dependencies [685494c]
- Updated dependencies [a1bc55d]
- Updated dependencies [2d82cf4]
- Updated dependencies [e4bdb26]
- Updated dependencies [611c8d3]
- Updated dependencies [6f28fe0]
  - @private-email/mail-core@0.1.0
  - @private-email/localization@0.1.0
