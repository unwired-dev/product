Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to the host TypeScript in `apps/mobile` and `apps/macos`.

A host owns views and native adapters. It renders shared stores from `@private-email/mail-core` and passes native modules into them. `apps/mobile` is Expo on iOS and iPadOS (Hermes, Expo Router split view); `apps/macos` is React Native macOS, where AppKit owns windows and each window mounts its own React root over one JavaScript runtime. The two hosts pin different React and React Native versions.

#### The host stays thin

- `registration-gate.tsx` offering a provider's first-mailbox or add-mailbox
  action when this build's native adapter cannot authorize that provider.
  Trace the native build capability and provider construction together, and
  check both setup and connected account settings with the capability absent
  and present. Mock builds must reflect their compiled provider; otherwise an
  optional missing client ID leaves a permanently failing action in both hosts.

- `Inbox` or registration copy deriving the provider label from Product Account
  presence. Inspect Microsoft-only and mixed-provider views as well as Gmail;
  use the selected connection's provider or neutral aggregate wording, or the
  interface labels Microsoft mail as Gmail despite independent authorization.
- `outbox.tsx.OutboxRow`, `statusOf` or `UnknownRecovery` defaulting provider copy
  to Gmail or another specific provider when the entry's Mailbox Connection is
  absent. Trace row status, Check Again feedback and the Edit warning after
  connection removal on both hosts; use retained provider evidence or neutral
  wording. Otherwise an unknown delivery directs the person to the wrong Sent
  folder and increases the risk of a duplicate resend.
- IMAP password repair in `RegistrationGate` available only when saved registration
  says authorization, while a current Inbox read can refuse a saved connected
  credential. Trace the Inbox notice through account settings without relaunch;
  every IMAP connection must offer repair, and IMAP waiting rows must never invoke
  Gmail consent. Otherwise refusal strands the connection or grants another provider.

- `RegistrationGate` splitting Account Settings into destinations without tracing
  the Inbox's targeted entry points. An explicit password-repair request must
  reach Email Accounts even after Open Inbox defers pending Recovery Key setup;
  default setup landing must not override that request. Retire the requested
  destination when its account/Inbox choice becomes invalid, or a later account
  can inherit the earlier repair destination. Exercise the real gate and repair
  form with both confirmed and deferred setup on each host.

- `registration-gate.tsx.SettingsPage` retaining a selected destination or child
  form state when foreground verification replaces its Product Account while
  Settings stays mounted. Scope the page lifetime to that account and retire
  the old requested destination; otherwise a new account inherits Email Accounts
  and its pending Recovery Key or device enrollment is hidden. Exercise account
  replacement from an open destination through the real gate on both hosts.

- Application logic in a component, hook or adapter: decoding a native result, deciding a registration or enrollment transition, retrying, merging or filtering mail state. That logic belongs in a `mail-core` store so both hosts and its tests share it.
- A store read any way other than `useSyncExternalStore(store.subscribe, store.getSnapshot)`, or store state copied into `useState` and kept in step by an effect. The copy goes stale between the event and the effect.
- A native module result used in the host before the shared store decodes it. The adapter passes the raw result through; see `src/private-storage.ts`.
- Effect imported into a component or hook. React code is plain TypeScript consuming stores.
- `evaluation-composer.tsx` or another host component defining a WebView/page-message
  Schema decoder instead of consuming a shared non-React decoder's plain result.
  Trace the page producer, every host consumer and malformed-message rejection
  through the shared package export; otherwise separate hosts can accept different
  payloads and malformed messages can mutate Drafts. Keep the host decoder separate
  from page-facing conversion code so Schema/Effect stays outside the packaged page.
- An import of `@private-email/convex`, `@private-email/mail-test-harness`, a `mail-core` path outside its `exports`, or the other host's source.
- The same logic added to both hosts in one change. Compare the added non-React
  helpers and projections across the hosts, including `ContextMenu` serialization,
  `MessageMenu` and row-menu action selection, and `useMessageCommands` filtering.
  Two copies drift in supported actions, ordering or native selection ownership;
  move the shared logic to `mail-core` unless it depends on a host API. Keep
  React subscriptions, rendering and native adapters in their host.

#### React correctness

- `apps/mobile/src/registration-gate.tsx.RegistrationPage` placing scrollable
  setup content beneath the status bar or home indicator, or retaining spacing
  from superseded frames. Compare initial scroll position and final controls
  with the approved phone frames and device safe-area insets; an expanded Figma
  canvas does not waive horizontal geometry or safe-area ownership.

- `imap-setup.tsx.ImapSetup` or another registration chooser replacing the
  registration action helper with a direct provider row that ignores the store's
  `busy` state. Preserve disabled navigation during pending account/mailbox work
  and restore it after settlement. Exercise a held native authorization through
  the real store and an attempted provider selection; otherwise the interface
  opens a competing setup form while its other registration actions are disabled.

- `mail-assistance.tsx.MailAssistanceSettings` wrapping a native `Switch` in a
  press handler that also saves its choice. Trace native event ownership on each
  renderer so one switch interaction produces one enablement transition; otherwise
  a Mac click can toggle twice or issue duplicate saves. Preserve the 28pt Mac
  and 44pt mobile targets. Check the native control's clickable bounds; a plain
  outer View's minimum height reserves layout space without enlarging that target.
  Qualify any separate enlarged touch handler with
  native interaction evidence rather than treating component events as proof.

- `settings.tsx.settingsButton` giving a short visible title whose words are
  absent from its target-specific accessible name. Trace every `options.title`
  caller and localized title/name pair, ignoring decorative punctuation and
  capitalization; otherwise Voice Control cannot invoke the visible action.
  Preserve the mailbox or device context while keeping the visible words in
  the accessible name on both hosts.

- `design.tsx.ContextMenu` assigning action IDs from section/item positions or
  callback object identity while native menus retain their original IDs. Identify
  each action by its operation and owning message or destination, and dispatch to
  its latest committed callback. Reject the ID once that semantic action retires
  or changes owner; otherwise a live snapshot can make a displayed read or move
  action execute a different one or silently do nothing. Exercise a recreated
  callback, a section insertion and a retired choice through the native event boundary.

- Mac context-menu content removing `selectable` text without an accessible
  labeled replacement, or retaining selectable text that handles secondary
  clicks before its ancestor menu. Trace the installed paragraph's native event
  and accessibility behavior; otherwise senders disappear from VoiceOver or the
  attachment name or `message-detail.tsx`'s received date opens the text menu
  instead of the attachment or message actions.
  On iPhone and iPad, also check the paragraph's selectable-text long-press
  recognizer before retaining `selectable` on an attachment filename; otherwise
  its Copy menu competes with the attachment's context menu.

- `inbox-bar.tsx.NewMessageButton` falling back to another sender when a specific
  mailbox is selected but cannot send. Only All inboxes chooses the first usable
  mailbox in the window's Profile; a selected mailbox without authorization or
  SMTP keeps New Message disabled. Exercise a receive-only selection beside a
  usable sender, then All inboxes, through the real Draft store. Otherwise a new
  Draft silently starts from an identity the person did not choose.
  The same applies when `inbox.tsx.Inbox` normalizes the window's view: a chosen
  connection whose Inbox store closes while it waits for authorization stays
  chosen (`mailboxes.ts.inboxChoice`); only a removed connection falls back to
  All inboxes. Exercise a lapse of the chosen mailbox beside a usable sender and
  check New Message, the heading and the sidebar selection; otherwise the view
  silently widens to All inboxes and New Message picks another sender.

- `sidebar.tsx.Mailboxes` deriving its entire connection list from open Inbox
  stores. Connections needing authorization can have no store; retain those
  definitions from the current Profile with a connection-local problem and the
  owning provider's recovery action. Check the missing-store state, successful
  recovery without duplicate rows and Profile isolation; IMAP password repair
  must open Account through the composer exit guard. Otherwise a saved connection
  disappears precisely when the person needs to repair its access.

- `sidebar.tsx.Mailboxes` or `mailbox-views.ts.mailboxSidebar` exposing a connection's
  storage, retry or authentication problem only in the selected Inbox. Keep each
  store-backed connection's problem beside its sidebar row, independently of the
  window's mailbox selection, and retain access to its owning Inbox recovery
  controls. Exercise a failed connection while another mailbox is selected and
  after recovery; otherwise switching mailboxes hides a connection needing repair.

- `sidebar.tsx.FolderRows` or `mailbox-views.ts.failedFolders` losing a folder-local
  read failure when navigation unmounts its list notice. Subscribe to the owning
  IMAP store's folder updates independently of its Inbox snapshot, keep the
  warning on the exact failed folder row after switching destinations, and clear
  it on successful recovery or folder retirement. A primitive snapshot encoding
  must preserve every admitted folder name, including embedded separators, without
  marking healthy siblings. Otherwise a connection appears healthy despite unreadable
  folders, or one folder's failure is attributed to another.

- `organize.tsx.GmailMessageActions` returning saved-only explanations or other
  persistent notices inside the reader's fixed-height toolbar or iPhone capsule.
  Trace every capability branch with replies available and organizing disabled:
  keep response controls in the toolbar and render status through the quiet-fill
  `Notice` in scrollable reader content. Otherwise offline or pending provider
  checks clip the explanation or permanently cover message headings and bodies.
  Opened Labels/More popovers retain their deliberate floating placement.

- `message-detail.tsx.ResponseActions` rendering response preparation or failure
  text inside the fixed-height toolbar or iPhone capsule. Keep the buttons there
  and report status in scrolling reader content for its owning message, preserving
  live-region and failure-alert semantics. Trace progress, rejection and retry
  on both hosts; otherwise the toolbar clips feedback or its capsule grows over
  the message while a response is being prepared.

- `apps/mobile/src/message-detail.tsx` or collaborating reader chrome choosing
  iPhone-only controls from window width alone. Keep the iPhone Back header,
  bottom toolbar and Reply picker in landscape too, and preserve the iPad's
  documented toolbar behavior at narrow widths. Trace `organize.tsx.Toolbar`
  panel anchoring against that same device choice; otherwise Labels and More
  can open below the bottom toolbar, outside the viewport. Exercise a wide
  iPhone and a narrow iPad through the real reader stores, and retain native
  orientation and multitasking qualification separately from component evidence.

- `message-detail.tsx` displaying a conversation count from a constant or only
  the opened message. Trace ordinary Inbox selections through the single-message
  route with a cached multi-message Thread: omit the count there or derive it
  from the mailbox-scoped Thread projection. `ThreadMessages` must count that
  same projection, or the reader mislabels multi-message conversations.

- Mac `inbox.tsx.statusOf` or `headingOf` deriving connectivity only from cached
  Inbox state while an explicit online search reports an `offline` failure.
  Trace the online answer as well as the displayed mailbox states: an unreachable
  server must select the documented Offline subtitle instead of a result count,
  while preserving Syncing precedence. Exercise partial failure, fresh retry and
  query/scope replacement through the real search store; otherwise current cached
  mail makes a failed online search appear connected. On iPhone and iPad, where
  search replaces the subtitle with scope controls under #974, preserve each
  connection's failure under From mail servers instead of requiring that subtitle.

- `sidebar.tsx.FolderRows` localizing every folder with the inbox role as
  Inbox. Only the reserved normalized `INBOX` name matches `inboxFolder`; other
  role-bearing folders keep their provider name and separate selection. Exercise
  INBOX beside a differently named inbox-role folder on both hosts; otherwise
  distinct folders appear to be the same Inbox.

- `inbox.tsx` retaining the Inbox title while the sidebar selects a
  different IMAP folder. Trace the effective folder from `useImapFolder` into
  the visible and accessible list heading on both hosts, including names with
  embedded newlines and fallback after folder retirement. Otherwise the list
  labels Archive or another folder's messages as Inbox. Preserve the Mac search
  title while searching, the iPhone/iPad search scope controls under #974, and the
  aggregate Inbox title for aggregate mail.

- `imap-setup.tsx.ImapForm` deriving password-repair guidance from the manual
  setup provider, or rebuilding the saved endpoint from a recognized preset.
  Use the saved host and port to choose the heading and app-specific-password
  note, while retaining the saved host, port and successful username for setup,
  including iCloud's full-address fallback. Otherwise repairs hide required
  password guidance or authorize a different connection identity.

- `imap-folders.tsx.useImapFolder` treating only a `failed` folder view as a
  synchronization failure, or retaining a choice absent from the ready listing's
  selectable folders. Use the shared IMAP projections: cached `ready` rows with
  `retry` or `authentication` still need the folder notice, and a removed,
  renamed or non-selectable choice is retired to Inbox and cannot revive when
  that name reappears. Exercise both hosts, including folder recreation;
  otherwise stale mail appears current or returns from an obsolete choice.

- `evaluation-composer.tsx.EvaluationEditor` or `composer.tsx.Editor` retaining
  failed-Close feedback after accepting another authored edit. Retire the stale
  notice and its recovery controls on every accepted editing path, while keeping
  the current save status visible. Malformed messages and retired-owner callbacks
  must not clear feedback. Exercise blocked Close, resumed editing and notice
  removal on each affected host; otherwise successful autosave can appear beside
  an obsolete save-failure notice and Retry action.

- `evaluation-composer.tsx` or another host view reusing notice copy that promises
  a recovery action its failure state does not offer. Trace each advertised action
  to a reachable control and handler in that view, including its storage and
  capability refusals; otherwise shared copy can send the person toward an
  unavailable escape such as Discard. Use view-specific copy when the action is
  outside the view's authorized scope, and check the visible failure-and-retry
  journey on each affected host rather than requiring extra product controls.

- `trusted-devices.tsx.TrustedDevices` or registration/account routing hiding a
  native-retained actionable proposal behind a coarse capability gate such as
  `approvesDevices(privateSync)`. Read `revocationProposal` before that gate:
  device-key loss can leave `privateSync: enrollment-needed` with a submitted
  removal whose exact replay and receipt reconciliation remain authorized.
  Keep its replacement key and Confirm/Cancel reachable without restoring device
  approval or new-removal entry points. Trace settings, Inbox landing and store
  actions through the native custody checks; Cancel without a receipt must keep
  the proposal, and a settled proposal may require fresh enrollment. Otherwise
  an unanswered removal and its Recovery Key become stranded behind the UI.

- `composer.tsx.Editor` accepting edits while Send freezes an immutable Draft for
  admission. Disable text, keyboard, pointer and accessibility editing controls,
  and fence their callbacks synchronously before awaiting admission: render props
  and ancestor `pointerEvents` do not retire queued native input. Include history,
  Markdown, translation and assistance Apply/Close, sender/recipient changes and asset Remove/Cancel;
  keep picker/paste/drop lifetime fences. On refusal restore editing and ordinary
  saving. Otherwise an accepted edit is neither sent nor saved when Send closes.
  Dismiss captured translation and assistance input at Send and fence new captures;
  otherwise queued native input can restart generation while admission is pending.
  Exercise queued callbacks before React commits, successful admission and refusal
  followed by durable editing; props-only assertions miss this data-loss window.

- `composer.tsx` clearing a Send refusal only on one editing path. Clear stale
  refusal feedback whenever an accepted edit changes the authored Draft, including
  Undo/Redo and Markdown edits that bypass `change`; preserve feedback while a
  frozen Send is pending. Otherwise restoring a valid recipient still announces
  that the message has none. Exercise the visible refused-Send-then-Undo journey.
- `composer.tsx.Editor` eligibility checks repeating whole-document projection
  through a shared helper. Follow render-called helpers, including `selectedText`:
  a capped result does not bound its earlier `bounds`/`covered` allocations. For
  a collapsed-caret Rewrite existence check, use `assistance.ts.canRewrite`'s
  early exit over non-image authored spans rather than a whole-body selection.
  When a render check needs a document length, reuse the existing `display` for
  that body revision; otherwise every keystroke repeats document-wide allocation.
  Preserve selected-range eligibility and capture-time size/image refusal.
  Press handlers must still use `authored.current` and event-facing selection
  so reuse does not admit stale input before React commits.

- `apps/macos/src/mailbox.tsx.InboxProvider` installing one application lifecycle
  subscription per mounted window on the shared Draft store. Give that store one
  subscription owner across windows, preserving later distinct transitions and
  removing view-owned subscriptions after their final owner closes. Exercise real
  synchronization through the external pull boundary with multiple windows,
  one closing and reopening; otherwise each activation queues redundant network
  passes, while premature cleanup leaves surviving windows unable to refresh.

- `mailbox.tsx.InboxProvider` discarding a rejecting `drafts.sync()` Promise from
  automatic AppState callbacks. Use the store's `syncInBackground` action so
  foreground and background passes consume and log defects through the canonical
  diagnostic boundary; explicit `sync` must still reject to awaiting callers.
  Exercise both lifecycle states with the real store and a failing subscriber,
  then verify later synchronization. Otherwise the host bypasses the core's
  automatic catcher and creates unhandled rejections.

- `message-detail.tsx.AttachToNewMessage` offering creation without an eligible
  sending mailbox or ready Draft storage, or swallowing an unexpected
  `attachReceived` rejection. Keep unavailable-storage feedback and retry in the
  reader itself, since the iPhone reader can hide the Inbox's Draft notice. Trace
  every undefined result through `composer-navigation` and the real Draft store:
  refused composer exit, superseding navigation and invalidated ownership are
  intentional outcomes, not generic attachment failures. Check sender eligibility
  changes and failed/locked storage recovery through the visible reader; a mocked
  `Drafts.create` rejection proves only the defensive catch. Expose standalone
  failures through an accessible labeled parent on Mac, or VoiceOver misses them.

- Mac `message-summary.tsx` or `translation.tsx` rendering standalone title,
  progress, failure, omission or privacy disclosure only in nonselectable `Text`.
  The installed Mac Fabric paragraph is not an accessibility element; use
  selectable text or an accessible labeled wrapper. A generic panel label alone
  does not expose its children. Otherwise VoiceOver reads the result but misses
  why it is partial, unavailable, inaccurate or unsaved. Keep labels inside native
  controls owned by those controls; component evidence does not qualify VoiceOver.

- Mac `composer.tsx.transferred` relying only on a pasteboard/drag item's optional
  MIME type to choose inline image insertion. An item with no type may still carry
  its media type in a data URL; infer that type before `prepareFiles`, normalize
  supported image aliases and keep byte verification at the owning store. Otherwise
  a pasted image silently becomes an Attachment instead of an Inline Image. Cover
  absent/empty type through the visible paste journey and preserve ordinary files.

- `composer.tsx` independently patching equal body identities in `authored.current`
  and Undo history when an asset import settles. Preserve their shared immutable
  body identity through that metadata patch; Draft translation captures from the
  authored ref and checks the rendered history identity. Otherwise every translation
  opened after an image settles is immediately discarded, even for surrounding text.
  Exercise the visible selection journey after settlement, not only after reopening.

- `composer.tsx.usePreview`/`AssetRow` checking complete Inline Images while
  treating complete Attachments as healthy without reading and verifying their
  native bytes. Trace every complete asset kind through `store.readAsset` and
  `RegistrationStore.readDraftAsset`; verify-only reads must keep attachment
  bytes native and preserve missing/damaged feedback and the store's locked
  outcome. A transient locked result must say verification was refused and allow
  another check, including on foreground activation while locked; test explicit
  retry and the host lifecycle event through the visible composer. Otherwise the
  composer claims an ordinary attachment is healthy after its bytes are lost or
  damaged, or permanently hides an Inline Image after storage unlocks. Fence
  retry, replacement and unmount results as for image previews, and remove
  foreground subscriptions when their row no longer needs them.
- `composer.tsx.transferred` or picker handlers constructing a prepared asset,
  starting an import or mounting a row for every selected file before applying
  `drafts.ts.pickLimit`. Bound each pick, paste and drop before that amplification,
  with `store.pick` owning picker-copy cleanup; otherwise a large user selection
  blocks the shared host runtime even when each file meets its byte limit.
- `message-body.tsx` or `translation.tsx.MessageTranslation` flattening all readable
  spans during render before the shared translation input cap applies. Pass the
  structured readable body to the bounded shared builder and memoize by body;
  otherwise opening or rerendering a long message traverses its whole text even
  when Translate is never pressed.

- `translation.tsx.ReaderTranslation` hiding a dismissed panel while leaving its
  queued language, Retry, Cancel or Dismiss callbacks authorized by the mounted
  store. Retire the open session synchronously and check that exact session
  before acting, including after reopening the same message. Check the live
  store's exact result before Retry or Cancel within that session too; a target
  change retires the previous request's controls. Otherwise stale input starts
  hidden inference or replaces, cancels or closes a later translation.

- `MessageDetail` or `ThreadView` inheriting the Account/Draft gate’s Default
  Profile consent for a reader of another Profile. Check the reader gate and
  `useMailAssistanceLifetime` against the same explicit reading Profile, including
  revocation and Profile replacement; otherwise Default consent exposes another
  Profile’s mail to assistance or queued input revives a discarded preview.
  Preserve staged Account settings and Draft consent until their ownership lands.

- `mail-assistance.tsx.MailAssistanceSettings` presenting an Off choice as saved
  after `setEnabled` catches a Keychain rejection. Keep the gate immediately off,
  but show unsaved status and retry the desired choice with account ownership
  intact; otherwise the person sees only Turn on while the persisted preference
  remains On and cannot directly retry the failed Off save. Exercise native-save
  failure and recovery through both rendered settings surfaces.

- `mail-assistance.tsx.MailAssistanceSettings` adding the device-local opt-in
  without ADR 0053's explicit Account Settings availability check and product-owned
  status. Trace the settings route's injected `NativeAssistance` outside
  `MailAssistanceGate`; opening settings or toggling On must not check availability,
  prewarm or infer, and Off must refuse queued checks. Retire pending checks and
  shown status on account/provider replacement, Off and unmount. Exercise the
  rendered settings surface on both hosts, including unavailable outcomes and late
  replies; a reader-only capability check leaves opted-in users unable to explain
  system unavailability until they attempt generation.

- `translation.tsx.useLanguages` querying native Translation from a pending passive
  effect after Mail Assistance Enablement turns off. Reuse the request owner's
  live enablement predicate at that call boundary; hiding the panel on a later
  render does not retire its pending effect. Exercise Off between layout setup
  and passive effects, or a disabled account can still reach Apple Translation.

- `translation.tsx.DraftTranslation` accepting captured ready text without checking
  the live store's exact result and committed owner, or `composer.tsx` invalidating
  the captured selection only after rendering. Recheck acceptance after a target
  change, Keep Original, body editing followed by Undo before commit, and unmount.
  Clear capture ownership synchronously on editing and dismissal; returning to
  the same body identity cannot restore a discarded preview. Otherwise queued
  native Replace input applies a superseded language or dismissed translation.

- `message-summary.tsx.MessageSummary` retiring its store only in a passive
  effect. A pending availability check can settle after the replacement reader
  commits but before that cleanup, starting inference on the previous message.
  Discard request ownership during layout cleanup on message, mailbox/account,
  captured-input or assistance-provider replacement and unmount; fencing queued
  button callbacks alone is insufficient. Preserve store reuse through
  StrictMode's setup/cleanup/setup replay. Check cancellation at the commit
  boundary with the real store and a controlled native provider, since an
  assertion after `act` flushes passive effects cannot detect this gap.

- `Editor` keeping a new `rebind` callback for each parent `onRebind`, or releasing
  identity tracking on unmount while Close or Discard still uses `authored.current`
  to resolve a conflict copy. Keep one stable callback, read the committed owner
  callback, and release it when its mounted editor and active finishing operations
  no longer own it. After unmount, advance only the pending operation's authored
  identity, without updating history or calling the route/window owner. Finish
  failed-discard restoration before releasing, including refused/rejected saves,
  and reset mounted bookkeeping on layout-effect setup for StrictMode replay.
  Otherwise refused saving retains dead editors indefinitely, or a pending
  Discard reports success while leaving its rebound version durable.

- `composer.tsx.Editor` or `ComposerActions` allowing Close, Send or Discard to
  overlap a pending finishing operation. Disable Compose actions as well as
  Close and Send while closing saves, and guard queued callbacks synchronously
  with the current operation ownership. Ordinary typing may continue but must
  not clear the pending state. Exercise a held native commit, an already-open
  overflow's queued Discard, queued Close and later typing, then durable Close
  completion; otherwise Discard or an edit re-enables controls and starts a second
  close, deletion or delivery operation against the same Draft.
- `composer.tsx.Editor` putting variable-height save status, errors or
  confirmations outside its single outer content scroll. Verify failed saving,
  refusal and Discard feedback with the body/fields in that scroll; otherwise
  stacked banners consume a short overlay or keyboard-reduced viewport and
  cannot scroll away. Preserve ADR 0057's platform-placement amendment: the
  fixed mobile From row, Mac From/Send footer, Mac/iPad top format bar and compact
  iPhone above-keyboard format bar are deliberate exceptions. Do not apply the
  superseded header-only-fixed constraint to those controls.

- `Editor.close` catching failure only through `createComposerNavigation.leave`.
  The Close button also calls it directly as `void close()`: catch unexpected
  rejection from both `save` and empty-only `discard`, keep the editor open,
  settle its Saving state to retryable blocked feedback, and resolve false.
  Otherwise direct Close leaves an unhandled rejection and a disabled button,
  while guarded navigation refuses silently with the same stuck editor.
- `Composer` replacing an empty editor with its unavailable fallback before a
  successful Close or Discard resolves. Removal can unmount the editor before its
  Promise settles; notify only the still-mounted composer that still owns that
  Draft, rather than skipping completion because the editor retired. Exercise
  untouched New Message Close and Discard, plus ownership changes while finishing;
  otherwise the window remains on an unavailable Draft and its floating bar stays
  hidden after the Draft was successfully removed.

- `message-detail.tsx.MailboxMessage` offering compact New Message only when the
  opened mailbox can send. Use the eligible senders in that reader's Mail Profile,
  preferring the opened mailbox and otherwise the same first sender as the Inbox.
  Exercise a read-only IMAP mailbox beside an eligible sender, with an earlier
  sender in another Profile; otherwise the compact reader hides a supported
  action or creates a Draft in the wrong Profile. Preserve unavailable Draft
  storage and retired-reader creation fences.

- `inbox-bar.tsx.NewMessageButton` guarding only `useLeaveComposer.leave` rather than the
  whole New Message action. Acquire its event-facing latch before awaiting
  leaving, hold it through `store.create`, and keep the visible button disabled
  until refusal or completion releases it. A second press after leaving settles
  but while persistence is pending otherwise creates another blank Draft. Check
  refused leaving, failed storage and owner/unmount changes without resetting
  an in-flight latch merely because the component rendered again.
  Use the shared creation coordinator so later accepted navigation wins while
  the newly selected Draft survives cleanup. Draft selection must name its
  destination to that coordinator; a row becomes selectable before creation
  finishes, so an empty selected composer must not be treated as abandoned.

- Mobile `Editor` treating `onKeyPress` Backspace as physical deletion direction,
  or absence of that event as Forward Delete. Trace the installed iOS delegate,
  Fabric emitter and TextInput wrapper: empty replacement text synthesizes
  Backspace regardless of direction, while edits bypassing the delegate may
  emit no key at all. Use edit-correlated selection/range evidence, including
  the post-edit caret, and consume it for that text event; otherwise repeated
  characters with different marks lose the wrong formatting. Cover software
  and hardware deletion, selected cut, word/grapheme removal and autocorrect/IME
  paths; keep missing native qualification explicit rather than inferring it
  from a component test.

- `Editor.edit`, `format` or `block` using render-captured body selection or
  typing marks. Native selection and text events, toolbar/keyboard formatting
  and Undo/Redo can arrive before React commits. Advance event-facing selection
  and mark overrides synchronously, including placed Markdown/block selections,
  caret-move resets and history travel; otherwise repeated text edits target the
  wrong marked character or carry the old caret's formatting to a new position.

- `Editor` computing repeated commands such as Undo/Redo from render-captured
  history. Native and keyboard callbacks can run more than once before React
  commits: advance from the latest history synchronously for each accepted
  command, and save that same present payload. Keep all history writes on that
  path, including rebinds, typing breaks, Markdown markers and Close. Do not
  mutate refs or save inside a React updater that StrictMode may replay;
  otherwise commands collapse to one step or persisted content diverges from
  the displayed history.

- `Editor` retaining its old Draft identity after conflict preservation. Follow
  the authored version through in-process forks, storage rebases and edits racing
  deletion; its route/window selection, past/present/future history, continued
  editing, Close and Discard must all follow the same copy without remounting.
  Check text callbacks arriving before React commits a rebind: keep the prior
  authored payload and identity current synchronously, and use functional history
  updates, or the next event forks extra copies or deletes another editor's work.
  Build each field command, recipient completion and Close from that latest
  authored payload too; pairing a fresh save baseline with a stale render payload
  silently erases edits from another field before React renders.

- `Recipients` or `Editor` keeping unfinished recipient text only in component
  state instead of the autosaved Draft. Verify interruption recovery without
  blur, Close or navigation, and include unfinished entries in content equality,
  conflict preservation, empty-Draft disposal and Undo/Redo. Otherwise authored
  addresses disappear after termination despite a saved Draft, or a stale empty
  editor deletes another window's work.

- Composer text editing that infers a replacement solely from identical display
  text instead of using the selection and deletion direction, or coalesces Undo across fields or caret
  moves. Check repeated characters with different semantic marks and subject-to-body
  editing; otherwise formatting moves to the wrong character or Undo removes an
  unrelated completed edit.
  Subject word grouping must inspect the newly inserted character at the saved
  caret, end on any whitespace, and start a distinct step for multi-character
  insertion or replacement; the final character of the entire subject says
  nothing about typing in the middle of it.
  Mac `onKeyDown` emits ordinary keys too: require the modifier before invoking
  formatting or Undo, or typing a letter can mutate formatting/history.
  In the installed Mac TextInput, `keyDownEvents` consumes matching native input;
  it does not limit callback dispatch. Trace the native emitter and JavaScript
  wrapper before adding a key to that list or replacing native text editing.
  Otherwise a key is swallowed without editing, or JavaScript competes with an
  unmatched native edit. Preserve modifier-specific deletion, composed characters,
  selection state and marked-text handling when intercepting editing keys.

- Mac composer shortcut registration or `Editor.keyDown` comparisons that assume
  letter keys stay lowercase with Shift. Match both layers against the installed
  emitter's reported key and modifier flags: `RCTViewKeyboardEvent` uses AppKit's
  `charactersIgnoringModifiers`, which retains Shift, while `RCTHandledKey` and
  the TextInput wrapper compare keys case-sensitively and default omitted
  modifier fields to false. Normalize a callback only within the intended
  shortcut family and register each supported chord's reported key; otherwise
  Shift-Command-Z misses semantic Redo or runs alongside unmatched native editing.
  Keep unshifted formatting shortcuts and native marked-text handling intact.

- A voluntary destination change that unmounts the Inbox or replaces its composer
  without awaiting the guard returned by `useLeaveComposer`: trace Account/RegistrationGate,
  mobile route replacements, Mac pane changes, New Message and Draft/message
  selection through the registered editor close callback. It must finish pending
  recipient text and wait for durable saving, holding the destination on invalid
  input or failed storage; otherwise unfinished addresses and unsaved edits are
  lost. Distinguish forced account/device invalidation, which must purge private
  state, and AppKit window destruction from voluntary navigation. Cover invalid
  entry and failed saving through the affected exit, not only the Close button.
  `createComposerNavigation.leave` must also release its pending guard when the
  registered finish callback rejects: refuse that destination and permit a later
  attempt, or one unexpected failure blocks navigation for the session.

- Reviewing a Mac composer exit only through React callbacks. Inventory native
  window close and application Quit alongside router/pane navigation, applying
  `.opencodereview/rules/native.md`'s AppKit exit check to the collaborating host.
  The AppKit lifecycle exception above distinguishes ownership, not durability:
  a shared store survives window destruction but not process termination.

- Assuming router removal hooks cover native split-column navigation in mobile
  `app/_layout.tsx`. Trace the installed Expo Router and screens implementation:
  compact system Back/swipes can hide the secondary column without changing its
  route or invoking `useLeaveComposer`. Layout/appearance notifications do not
  establish a cancellable transition. Require a qualified native guard or an
  explicit pre-release gap with visible unsaved-state recovery; never report an
  Inbox warning as a completed Back guard. `useOpenDraft` must reveal an already
  selected editor without attempting to leave it, or invalid recipient entry
  can strand the hidden editor behind a refused destination change.

- Mobile `app/_layout.tsx` keeping route state in a ref such as `reader` for a
  callback that runs after an awaited save (composer Close, `compose`) while
  only a render-time `useLayoutEffect` refreshes it. Installed Expo Router
  queues `router.replace` and dispatches it from an effect, and `setParams`
  reaches the layout's params only on a later render, so a save can settle
  before the destination renders. Every handler that changes the ref's source,
  including selection behind the composer and an Inbox row action closing the
  selected reader, must update the ref before navigating. The same holds for
  the open Draft: a palette Go To Inbox or Search Mail runs the composer's
  Close and then the Inbox `onClose` from one render's closures, so `onClose`
  must read the `composing` ref, not `draft`, or it reopens the closed composer.
  Otherwise a delayed Close or New Message returns to a reader that was just
  replaced or removed. The Jest router mock commits synchronously and cannot
  show this ordering; a passing routing test is not evidence.

- `Editor` suppressing autosave during explicit Discard without retaining the
  latest authored payload and restoring it when deletion fails or rejects.
  Text and Undo events can still arrive while storage is pending; trace rendered
  history, the authored ref and subsequent Close/reopen, or visible accepted edits
  disappear. Cancelled confirmation must leave saving enabled; a completed own
  discard must suppress queued callbacks so they cannot recreate its Draft.
  Freeze the accepted Discard content while allowing its identity and conflict
  metadata to follow earlier queued saves. A text event accepted while saving
  is suppressed must not change the expected deletion content; otherwise waiting
  behind autosave makes the editor's own stored Draft look like another writer's
  version and closes the composer without discarding it.
  On failure or rejection, restore late edits against that same frozen content
  rebound to the editor's current identity and conflict metadata, including
  repeated rebinds. Passing the original identity as `store.update`'s baseline
  after its edit moved creates an extra conflict Draft instead of updating the
  existing copy. Do not normalize arbitrary mismatched baselines inside the
  store without evidence that they belong to the same editor/version; identity
  and conflict metadata are part of its content-equality contract.

- `src/mailbox.tsx.useSavedBodies` refreshing derived cache-status labels only
  after query, scope or reader events. Subscribe while results are shown to the
  shared body-cache mutations, including background prefetch and eviction from
  another connection, and unsubscribe on cleanup. Fence overlapping replies for
  the same results as well as replaced results; otherwise rows keep claiming
  downloadable or saved after the device cache changes.

- An effect that subscribes, listens (`AppState`, `Linking`, a native emitter) or starts async work without returning cleanup, or whose async result is applied after unmount or after its inputs changed.
- A store action whose returned Promise is awaited in render or left to reject; actions are fired as `void store.action()` and report failure through state.
- An event handled indirectly by an effect that can repeat a store action or apply it to a later selection; trace the user handler and the effect to prove the incorrect transition.
- A list key built from an index where a reorder attaches selection or row state to the wrong message.
- `message-body.tsx.Presentation` retaining render failure across replacement rich
  documents, or `RichDocument` reusing measurement state/native event identity for
  a replacement. Scope failure to the failed document and reset the native view
  and measured height for a fresh document. Trace late error/size callbacks and
  the store's expected-presentation reservation fence; otherwise recovered images
  remain hidden while charged, or stale events poison the replacement reader.
  Keep only a small failed-document identity in mounted state, not the discarded
  rich object; otherwise its expanded HTML/data-image strings remain retained
  after the view and reservation have been released.
- `message-body.tsx.GmailMessageBody` retaining presentation-scoped Ask consent
  through a policy transition or reader-owner replacement that revokes it. Never must discard that consent,
  including when another Mac window changes the policy and returns to Ask while
  this reader stays mounted. Check every identity the consent belongs to against
  the actual component key: a message-ID-only key does not remount when another
  Inbox shows the same Gmail ID. Discard consent on that owner change so returning
  to the original Inbox cannot restore it; otherwise later viewport input resumes network
  loading without another Load images action. Preserve Always Load and the
  fail-closed unresolved-policy state, and exercise the transition through the
  real settings store and reader rather than only checking the button.
- Per-row work in the Inbox `FlatList` that grows with the mailbox: an unstable `keyExtractor`, a row that subscribes to the whole store, or sorting and filtering repeated on every render.
- `message-detail.tsx.ThreadMessages` or another multi-message rich reader treating
  bounded download concurrency, image reservations or viewport fetch priority as
  a bound on mounted bodies. Trace mounted `GmailMessageBody`/WebView instances and
  rich-document preparation separately from request scheduling; otherwise a long
  conversation creates a native view and prepared document for every cached
  message even while downloads are capped. Check the task's accepted scope before
  requiring windowing: #809 explicitly defers bounded rendering to #862, and its
  operational docs and changeset must retain that limitation until qualified.
- `composer.tsx.DraftRowView` or a message row flattening an entire body before
  native `numberOfLines` truncation. Bound preview traversal and intermediate
  strings before rendering, including a single large span and many empty blocks;
  memoization does not protect the edited Draft whose identity changes per edit.
  Preserve short-body whitespace and Unicode boundaries. Inspect recipient/header
  summaries and accessibility labels separately before claiming all row work is
  bounded; otherwise a valid large Draft stalls the shared JavaScript runtime
  when the Inbox opens or on each visible body edit.
- An unbounded Draft/message collection rendered with `map` inside the Inbox
  `FlatList` header/footer or another scroll container instead of its virtualized
  data: virtualization covers list items, not nested header rows, so mounting a
  long collection renders every row. Trace mixed-item keys, selected state through
  `extraData`, accessibility names and the received-mail empty state; a long-list
  integration check must show that mounted rows are bounded. When moving a store
  subscription into `Inbox`, keep `inboxMessages` sorting tied to mailbox/scope
  changes rather than every Draft autosave, and keep unchanged Draft-row callbacks
  stable so memoization can avoid body-preview work on every keystroke.
  Keep the Drafts heading conditional on the same search mode as its rows;
  otherwise received-mail-only search exposes an empty Drafts section to sighted
  and accessibility users. Preserve New Message and storage-recovery controls.
- `inbox.tsx.Inbox` combining a standalone search-header section with
  `mailboxes.ts.messageDateSections` without accounting for its empty `saved`
  fallback. Keep one saved-result header/empty notice and unique section keys
  with no local matches, including provider-only results; otherwise iPad search
  duplicates Top Results or its no-matches notice. Exercise both platforms and
  retain their deliberate day-divider difference.
- `inbox-filters.tsx.useInboxFilter` treating a saved enabled flag as proof that
  its settings narrow the current view. Reconcile eligible connections after a
  scope change or connection removal, and use the effective active state for
  rows, the bar and filtered-empty copy; otherwise exclusions that no longer
  apply leave an enabled control labelled Filtered by None. Returning to a scope
  where the retained settings apply may restore filtering without resetting them.
- `inbox-rows.tsx.Marked` giving matches the same weight as their unread parent.
  Compare the surrounding sender and subject with the matched spans in unread
  search results, not just the nested span's style. Preserve ordinary Inbox
  unread emphasis; otherwise bold matches have no visible emphasis where mail
  is unread despite a passing assertion on the span alone.
- `message-body.tsx.ReceivedAttachments` eagerly mounting a native row/control tree
  for every sender-controlled descriptor. The MIME part limit bounds decoding,
  not acceptable native view count; cap, batch or virtualize before constructing
  rows so a valid message with thousands of parts cannot exhaust the reader.
  Preserve the total and access to remaining attachments without downloading
  bytes, make disclosure keyboard-focusable and accessibly named, and reset its
  state when the owning message changes. Trace `messageAttachments` snapshot
  caching separately from native row construction; bounded descriptor projection
  alone is not evidence that every descriptor needs a native row.
- Selection held anywhere but its owner: route parameters on mobile, the window on Mac. A Mac window opened after another must start with no selection, and a read/unread change must reach every window without changing any selection.
- `window.tsx` or another reused reading host keeping selection or presentation
  state above the keyed `ProfileScope` boundary. A provider key retires only its
  descendants; place that state within the decoded Profile lifetime and exercise
  leaving and returning to the same Profile. Otherwise an old reader selection
  can reappear despite the Inbox clearing its query and mailbox choice. Preserve
  connection-owned stores and #646’s staged connection-Profile Draft/delivery
  boundaries.
- An Inbox row's removal action in `src/inbox.tsx` that leaves the selected message ID in its owning route or window after Archive, Trash or Spam. Trace accessibility actions as well as reader buttons through the owner's close callback; otherwise the row disappears while the reader reports unavailable. Undo restores mail without reopening that reader or changing another window's selection.
- `OrganizeStatus` announcing one shared `OrganizeNotice` once per mounted window or again on a late mount, or deduplicating solely by announcement text. One notice identity owns one accessibility announcement across the shared runtime; a later distinct notice with identical words must still announce. Trace every active announcement channel, including explicit calls and platform-supported live regions, rather than checking only the explicit call count. Preserve refusal alert semantics when removing an announcement channel. Verify the installed renderer's role and notification behavior before treating an `alert` role as automatic speech; component props alone do not qualify native VoiceOver behavior.

- `RegistrationGate` retaining an Inbox/Account destination choice after the Product
  Account changes or Inbox eligibility is lost. Discard that choice before
  rendering so new Recovery Key, enrollment or authorization steps govern landing.
  Also invalidate an earlier Inbox choice when different pending setup appears for
  the same eligible account; `inboxLanding` must compare the current setup with
  setup when the choice was made, including renewed enrollment codes and changed
  approval requests, so foreground restore cannot hide new setup.
  Preserve an explicit Account choice and an Inbox choice over unchanged setup.

- `message-body.tsx.AttachmentRow` accepting queued Download, retry, Open, Share
  or Cancel input after its reader changed or closed. Reuse `GmailMessageBody`'s
  committed mailbox/message and exact body predicate before these store actions;
  `readable(id)` and native file ownership do not identify the invoking reader.
  Check the switch's commit before passive `retainMessage` cleanup and a new
  download of the same message/part after the previous reader closes. Otherwise
  old input can expose a previous message's file or cancel a later reader's work.

#### Platform behavior

- Mac `command-palette.tsx.CommandBar` opening from its native Command-P listener
  while `message-body.tsx.LinkConfirmationProvider` covers that window. The
  background's accessibility suppression does not disable native menu events:
  check the window's shown confirmation before saving focus or mounting the query,
  and retain entry in other windows and after dismissal. Otherwise the hidden
  palette takes keyboard focus from the alert despite its full-window scrim.

- Mac `message-body.tsx.LinkConfirmation` leaving keyboard focus in the covered
  reader or allowing Tab traversal outside its choices. Background accessibility
  suppression does not remove AppKit key responders. Trace initial focus, forward
  and reverse Tab, Escape and activation through the installed view focus command,
  native responder chain and JavaScript key wrapper; otherwise a keyboard action
  can change mail behind the alert or dismiss it without an available choice.
  Include focus lost to selectable alert text: with no choice focused, Tab must
  enter at the first choice and Shift-Tab at the last, for both ordinary and
  caution alerts. A modular step from a missing-index sentinel can skip a choice.
  Keep native keyboard qualification distinct from rendered callback evidence.

- `apps/macos/src/message-body.tsx.LinkConfirmationProvider` or another Mac
  view using a React Native component whose native host is absent on macOS.
  Inspect the installed renderer's platform guards before relying on mobile
  component APIs: react-native-macos 0.81.9 excludes both legacy and Fabric
  Modal hosts. Use supported host views while preserving bounded content,
  dismissal and reader ownership; otherwise the confirmation has no native
  presentation even though types, bundles and rendered host tests pass.
- Mac link confirmation mounted inside `message-detail.tsx.MailboxMessage`
  instead of `window.tsx.WindowContents`. The window's selected mailbox store
  and message must gate its overlay; cover the glass sidebar, command bar and
  both columns and hide their background accessibility while it is open. Check
  independent windows and queued input after selection changes, or the alert
  leaves Mailboxes or the list usable beneath a partial scrim and can escape its
  reader's ownership.
  Core `accessibilityElementsHidden` and `accessibilityViewIsModal` are also
  excluded by the Mac renderer; preserve the AppKit background wrapper's
  accessibility-children and hit-test suppression rather than relying on props
  that rendered tests recognize but the native host ignores.
- `design.tsx.ToolbarButton` reporting a panel toggle as selected instead of
  expanded. Trace its `organize.tsx` callers through opening and closing the
  panel, preserving the visual open state and omitting disclosure state for
  ordinary actions; otherwise assistive technology reports selection without
  communicating whether the controlled panel is open.

- `design.tsx.Notice`, `label.tsx.Label` or another shared notice component
  dropping live-region, accessible-label or alert semantics during extraction.
  Compare every migrated asynchronous sync/authorization notice with its previous
  rendering, and trace the props to the actual accessible native element on each
  host; otherwise a notice appears without announcing that permission or
  connectivity changed. Preserve storage-failure alert semantics and keep actions
  separately reachable. Verify the installed renderer's announcement support;
  component prop assertions restore the contract but do not qualify VoiceOver.

- `imap-setup.tsx.ManualSending` explaining optional SMTP credential defaults only
  in single-line placeholders. Keep "same as incoming if blank" in visible,
  wrapping text beside each field, including after entry, and retain the field's
  accessible name. Otherwise narrow layouts truncate the default and entered
  values hide it. Check both hosts; native captures remain deferred when unavailable.

- Freshness or lifecycle changes in `src/freshness.ts`, host startup, or
  `InboxProvider` checked only against background execution. Verify each affected
  host against `docs/product/privacy-and-sync.md` and ADR 0013 within the issue's
  scope: launch/activation catch-up and the five-minute active-app fallback must
  both have an application owner. Mobile polling must follow the initial active
  state, stop outside active state and resume without duplicate timers; Mac work
  must outlive the last window and stop on Quit. An OS background registration or
  a screen activation callback alone leaves an open Inbox stale indefinitely.
  Exercise the timer with real registration/mailbox stores and a controlled
  native/provider boundary, keeping physical lifecycle qualification separate.
  In `apps/macos/src/freshness.ts.keepGmailFresh`, current push-route coverage
  must not suppress the five-minute poll while AppState is active: an APNs wake
  can be dropped or delayed without invalidating its route. Suppress covered
  intervals only outside active state, and verify that new mail appears while
  the app stays active with complete coverage and receives no wake. Check the
  installed native AppState semantics and launch state; otherwise a valid route
  can leave an open Inbox stale indefinitely until another activation or wake.

- A framework/OS-owned async executor, such as the `defineTask` callback in
  `src/freshness.ts` or a notification handler, that lets a thrown failure or
  rejected store action reach the framework's raw-error logger. Inspect the
  installed executor's failure path; catch at the host callback, emit only a
  fixed or allow-listed diagnostic, and fulfill its declared failure-result or
  completion contract. Otherwise a native/provider error can expose account or
  mail data even when application log calls are sanitized. Verify a private
  rejection resolves as failure without logging its fields.

- `composer.tsx.DraftRowView` showing its From address only as an empty-body
  fallback, or only in its accessibility label. Every Draft row must visibly
  identify its sending address alongside any body preview, including with
  multiple Gmail connections; otherwise adding body text hides the sender and
  makes the outgoing identity ambiguous. Check a populated body in both hosts,
  and keep rows sized to their content rather than introducing fixed-height
  list measurements that clip the added line or scaled text.

- `composer.tsx.DraftRowView` using a different recipient-role projection for
  its visible text and accessibility label, or concatenating To, Cc and Bcc
  without identifying each role emitted within the bounded prefix. Both hosts consume the shared Draft summary;
  check Bcc-only and mixed-role rows so confidential addressing is not announced
  as To. Explicit role words must retain meaning when punctuation is omitted;
  component label assertions do not qualify native VoiceOver pronunciation.

- A pressable without an accessible role and name, text that does not scale with Dynamic Type, a color taken from a literal rather than the light/dark tokens in `mail-core`'s `theme`, or selection and focus shown by color alone.
- `inbox-bar.tsx.FilterControl` retaining a sheet-specific `accessibilityHint`
  after a regular-width layout opens a popover. Trace the destination in compact
  and regular modes; name the common Filters destination or localize each
  presentation, or VoiceOver announces the wrong presentation.
- A primary action such as `inbox-filters.tsx.FiltersSheet` changing its pressed
  background to `accentInk` while keeping `accentOnFill` text or symbols. Check
  the held state in both palettes against DESIGN.md's contrast requirements;
  Dark's light ink token is not a fill for white foregrounds. Preserve the
  shared primary button's `accentFill` treatment, or the action becomes illegible
  precisely while it is being activated.
- `command-palette.tsx.usePaletteHeader` or another hook attaching
  `accessibilityActions`/`onAccessibilityAction` to a container `View` that is
  not itself `accessible`, such as the Inbox heading row or the composer's top
  bar. iOS exposes custom actions only on the focused accessibility element, so
  VoiceOver never reaches an action on a non-accessible container, while the
  testing library's `fireEvent` bubbles the event up from a child and keeps the
  journey green. Attach the action to the header's accessible element (the title
  `Text` or an `accessible` wrapper) and keep gesture responders on the wider
  container; otherwise the documented assistive entry point does not exist.
  `ActivityIndicator` is no carrier either: it gives `style` to an outer wrapper
  but forwards touch and accessibility props to a spinner-sized native view that
  is not an accessibility element unless `accessible`. Put the swipe on a
  full-size wrapper `View` and the action on an `accessible` element.
  Check modes that replace the ready heading too, such as
  `inbox-search.tsx.SearchHeading`: move the action to a focused accessible
  replacement, such as `inbox-bar.tsx.SearchField`, while retaining the header
  swipe; otherwise entering search removes the documented assistive entry until
  the user closes it, despite ordinary Inbox and loading states passing.
- A cross-cutting entry point such as `usePaletteHeader`, `CommandInput` or
  `RegisterCommands` added to `message-detail.tsx.MessageDetail` but not to
  every other screen the host mounts for the same state, such as
  `ThreadMessages` behind `app/thread/[id].tsx`. Enumerate the routes under
  `apps/mobile/app` and the Mac window's panes and check each screen the
  requirement names (Inbox, Mailboxes, message reading, composer, Settings);
  otherwise a route-specific reader has no palette while the documentation says
  it does. A split-view column that covers the Inbox on iPhone, such as
  `sidebar.tsx.Mailboxes`, also needs the header entry, and commands it can run
  that act on the Inbox column (Search Mail, Go To Inbox) must bring that column
  forward through `app/_layout.tsx`'s split view `show('supplementary')`;
  otherwise they run behind the covering column with no visible effect.
  Within each screen, check every early-return state branch too (loading,
  `StorageProblem`, `EmptyDetail` and `composer.tsx.ComposerFallback`, the
  composer's loading, locked, failed and unavailable states), on every route
  that renders it: on iPhone and in compact iPad layouts each covers the Inbox
  heading, so a palette entry only in the ready branch leaves no way to open
  the palette.
  Each branch needs both entries, the swipe and accessibility action for
  iPhone and the visible iPad `CommandInput` (`CommandInputRow` where the
  branch has no header); one without the other leaves that device without
  its documented entry.
  Check the new touch entry's effective hit area too: the iPad `CommandInput`
  is a 44pt-tall glass pill; keep its target at least 44pt without relying on
  `hitSlop`, as `Chip` and the compact `Button` do. A desktop-sized 36pt pill
  makes the iPad composer entry harder to activate.
- A reader control rendered for one store kind, such as the preview Inbox's
  Mark as read or unread in `organize.tsx.PreviewMessageActions`, without a
  `RegisterCommands` in the same component offering the same action list and
  handler as its buttons. Check each `organize.tsx.MessageActions` branch
  (preview, IMAP, Gmail and Microsoft) against the commands the palette names;
  otherwise the palette shows the command disabled beside a working button.
- A palette command left enabled while its matching button is disabled, such as
  `message-detail.tsx.ResponseActions` passing `responseCommands` a `starting`
  option not derived from the `pending` state that disables Reply, Reply All
  and Forward. Derive each command's `disabled` reason, or its omission, from
  the same state as its button; otherwise choosing the command closes the
  palette and silently does nothing, or starts the action a second time.
- `CommandPaletteProvider` or another cross-cutting provider placed relative to
  `registration-gate.tsx.RegistrationGate`, which replaces its children with the
  account page or the setup and locked pages. A provider below the gate leaves
  the account page (the app's Settings) without it unless
  `account-page.tsx.AccountPage` brings its own, as on iPhone and iPad, whose
  provider renders the open palette over its children. A provider above the
  gate, as in the Mac window, outlives every screen, so the open palette, the
  Command-P listener and the outside-click scrim must live in the mounted
  `CommandBar` and leave with it. Trace `app/_layout.tsx`, `account-page.tsx` and
  `window.tsx.InboxWindow` themselves, since test harnesses compose the provider
  on their own; otherwise the palette disappears from Settings, or an open
  palette, or Command-P before sign-in, outlives its screen with stale commands
  or an invisible scrim that swallows the next click.
- `inbox-heading.tsx` offering Search Mail, or another command that focuses or
  reveals a control in the Inbox column, without leaving the reader or composer
  route that covers that column on iPhone and in compact iPad layouts. Trace the
  command from a collapsed split view: it must leave the detail through the
  composer leave guard before focusing, and a Jest journey must assert the
  reader is gone, not only that the field exists; otherwise the command runs
  with no visible effect. The decision panel chose leaving the detail whenever
  one is open rather than tracking the alpha split view's collapse events.
  The Mac's expanded composer covers the Inbox column too: `inbox.tsx` Search
  Mail must collapse it through `window.tsx`'s `onReveal` before focusing (a
  #903 panel chose collapsing over leaving), or focus lands in a hidden field.
  Mobile Search Mail instead awaits the registered composer Close through
  `onLeave` before `onClose`; `_layout.tsx`'s composer callback clears expansion
  and `composing.current` before the reader callback chooses its route. Test an
  expanded regular iPad composer and failed recipient/save guards; do not infer
  that a Draft remains open from the reader's `onClose` callback alone or impose
  the Mac reveal policy on mobile.
- `app/_layout.tsx` asking its split view for a column by its two-column name.
  Mailboxes is the `primary` column and the message list `supplementary`: when a
  reader, Thread or composer closes, including the compact reader's own Back
  that hides the native navigation bar, and on first mount, show
  `supplementary`. Assert the requested column in the routing journey; otherwise
  iPhone returns to Mailboxes instead of the list, and iPad portrait opens the
  sidebar over it.
- `app/_layout.tsx` placing a composer overlay from a leading column's local
  `onLayout` alone. UIKit can move that column without changing its child bounds;
  derive the overlay edge from the native reading column's current width, including
  a regular split view with its leading columns hidden. Exercise sidebar movement,
  rotation and editor continuity; otherwise the overlay covers the interactive list
  or retains an empty gap beside the reader. Keep native geometry evidence separate
  from injected component layout events.
- `inbox.tsx` showing its floating search/New Message bar by default while composing,
  or unmounting it to hide it and losing New Message command registration. Preserve
  the hidden bar's guarded command, and the explicit Mac Search Mail reveal that
  collapses an expanded composer without closing its Draft. Focus search after the
  revealed bar commits; otherwise command availability or keyboard entry breaks.
- A floating Mac panel such as the Command Palette's, documented as closing on
  an outside click, that only handles Escape and Cancel. Render a transparent
  `Pressable` scrim with an accessible name while the panel is open, and keep it
  a sibling of the bar with a lower `zIndex`: React Native orders `zIndex`
  among siblings only, so a scrim mounted elsewhere covers the panel or never
  covers the content. Press it in the Mac journey; otherwise the documented
  dismissal does not exist or the panel's rows become unreachable. A panel
  hanging outside a non-clipping parent's bounds is not itself a defect:
  react-native-macos `RCTViewComponentView.betterHitTest:` (and Paper
  `RCTView hitTest:withEvent:`) keep searching children outside the bounds
  unless the parent sets `overflow: 'hidden'`.
- `message-detail.tsx.ThreadMessage` or another selected reader section marked
  only by a background color and `accessibilityState.selected`. Require a visible
  non-color cue such as a border, icon or text as well as assistive-technology
  state; otherwise sighted users in grayscale or with color-vision differences
  cannot identify the opened message. Check the cue against both palettes and
  the section's padding/radius, and retain increased-contrast native qualification
  as deferred when unavailable; component style assertions do not prove it.
- A component library, navigation library or native module added to either host without checking its owning host's accepted scope. Mobile uses Router's split view and React Native `StyleSheet`; native module additions must update that host's `scripts/verify-native.ts` allowlist and preserve its `scripts/verify-bundle.ts` renderer boundary. Otherwise a dependency can join the native graph without review or bring an incompatible renderer into the shipped bundle.
- Mac window identity, menu routing, focus or application lifetime handled in JavaScript. AppKit owns them; closing the last window keeps the app running.
- `command-palette.tsx.CommandBar` or another Mac overlay that takes focus
  and hands it back on dismissal through `TextInput.State.currentlyFocusedInput`
  alone. React Native tracks only text inputs, while Mac Inbox rows, buttons and
  the message body are keyboard-focusable, so a palette opened from a focused
  row returns focus nowhere. Save and restore the window's first responder
  through `UnwiredCommands.saveFocus`/`restoreFocus`, keyed by the AppKit window
  identifier. Both calls and the Fabric mount reach the main queue in call order,
  so saving before the open state change records the pre-palette control, and
  restoring before the command runs lets a command that focuses a field keep it.
- `command-palette.tsx.Palette` or another list whose highlighted row moves by
  keyboard while focus stays in a text field, without scrolling its
  `ScrollView` itself. Nothing native follows the highlight, so check Up and
  Down past the visible rows (Move to… with many labels or folders) and every
  reset of the highlight (a new query, opening the picker, going back) against
  the scroll offset; otherwise Return runs a row the person cannot see. Row
  places from `onLayout` are content coordinates only for the content
  container's direct children, and react-native-macos reports the offset of a
  `scrollTo` through a later `onScroll`, so a repeated key must not read the
  previous offset.
- A route, deep link or window identifier used before validation, or used to select a message in a store that has not confirmed it exists; the unavailable route must render.
- Mobile `app/thread/[id].tsx` or another deep-linkable reader calling
  `router.back()` unconditionally from its Back control. Check cold entry without
  history as well as pushed entry: return through history when available and
  otherwise replace with the Inbox retaining the decoded `profileId`. Exercise
  the actual route and visible destination with real reading stores; otherwise
  a cold-opened reader strands the person or falls into another Profile.
- A mobile Profile selector whose parameter name disagrees with ADR 0050’s
  `profileId` route contract. Trace targeted entry, in-app message selection,
  composing and reader/composer close through the layout’s decoded selector;
  absent values use Default, while malformed or repeated values fail closed.
  Exercise a non-Default target through real reading stores and route replacement
  so a renamed or dropped parameter cannot silently open Default.
- A deployment target, entitlement, Info.plist privacy string or App Transport Security setting lowered or broadened in `app.config.ts`, a config plugin or the Mac project.
- A Metro, Babel or config-plugin change that lets mock-session code (`UNWIRED_MOCK_SCENARIO`, `UNWIRED_REGISTRATION_MOCK`) into a build that did not select a scenario.

- A message WebView that relies on the wrapper's default origin whitelist. In
  `react-native-webview`, an unmatched URL can reach `Linking.openURL` before
  `onShouldStartLoadWithRequest`, bypassing confirmation. Pin the whitelist so
  every sender navigation reaches the cancelling delegate; check redirects and
  new-window links too. Keep a stable app-owned link identity through WebKit
  normalization; matching a callback URL to the raw sender string can lose the
  visible text and suppress mismatch warnings. Verify page-JavaScript disabling on the final native
  preferences object after any wrapper replacements, not just its initial value.
- Treating the owner-approved client-world measurement in ADR 0029's 2026-10-06
  amendment as permission for page scripts or sender-controlled bridge calls.
  The patched WebView on both hosts may run only its application-owned layout
  measurement through `callAsyncJavaScript` in `WKContentWorld.defaultClientWorld`
  while page JavaScript stays disabled; measurement failure must reach retained
  readable-text fallback rather than an indefinite loader.
- `GmailMessageBody` accepting a queued link choice without rechecking the current
  body/reader, or `LinkConfirmationProvider` revealing pending URLs without a live
  owner subscription and render-time check. Handoff-only guards leave a selectable
  previous-owner destination on screen. Compare the provider's current render
  mailbox/message as well as the reader's committed lifetime: a layout-ref change
  happens after the provider rendered and does not itself notify the Inbox store.
  Include mailbox identity in that lifetime even when the message ID is unchanged.
  Verify queued keyboard and WebKit choices after forget, message/account replacement
  and reader unmount in both hosts, including the commit before passive cleanup;
  stale Copy/Proceed callbacks must remain blocked too.
- `message-body.tsx.GmailMessageBody` dismissing a shared `LinkConfirmationProvider`
  confirmation without comparing its owning Inbox and message ID. Body replacement,
  reader cleanup and quote toggles must clear only that body's pending choice,
  using the latest pending state; otherwise message B dismisses message A's still
  valid destination. When a provider admits several messages, exercise a sibling
  transition with A's confirmation open and A's own invalidation, while preserving
  the existing stale-owner Copy/Proceed fences.

#### Bundle and workspace boundary

- A dependency declared with a literal version rather than its `catalog:` entry, taken from the other host's catalog, or added to `dependencies` when only tests use it.
- A change to a host's `scripts/verify-bundle.ts` (`apps/mobile/scripts/verify-bundle.ts`, `apps/macos/scripts/verify-bundle.ts`) that removes or loosens an assertion: the renderer inventory, the stale shared-source comparison, the rejection of the other renderer, Expo, React DOM or backend code in the Mac bundle, or the autolinking list. Version declarations do not prove what the bundle contains; these checks do.

#### Tests in the same change

Apply `docs/agents/testing.md`'s admission and proportionate-verification policy: existing meaningful coverage may suffice; document unavailable automation or protected/native evidence with its required follow-up. The cases below identify missing evidence for a named risk, not a requirement to add a test for every edit.

- A changed journey with no component integration test under the host's `test/` that drives the real `mail-core` store with a substituted native boundary. A rendered component test is not native E2E evidence; a Hermes export proves the bundle, not the behavior.
- A rendered-copy change in `Inbox`, shared host components or the localization
  catalog verified only with touched test files. Trace visible and accessible
  text consumers, including registration-to-Inbox and composer journeys, then
  run the full `pnpm test` suite for every affected host after the final copy or
  assertion edit. Reviewer fixes follow the same gate; otherwise an unrelated
  journey's exact-text lookup can fail after a focused review reports success.
- A test that mocks the store or asserts a callback was called rather than the rendered outcome.
- Unavailable native evidence reported as passing rather than deferred.

#### Leave to tooling

Hooks-rule violations (including synchronous state setters in effects and nested component definitions), formatting, unused exports, type errors and Effect import style are covered by oxlint, oxfmt, Fallow and the type checker. Inline styles are normal in React Native; flag a style only for a behavior defect.
