Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to the host TypeScript in `apps/mobile` and `apps/macos`.

A host owns views and native adapters. It renders shared stores from `@private-email/mail-core` and passes native modules into them. `apps/mobile` is Expo on iOS and iPadOS (Hermes, Expo Router split view); `apps/macos` is React Native macOS, where AppKit owns windows and each window mounts its own React root over one JavaScript runtime. The two hosts pin different React and React Native versions.

#### The host stays thin

- Application logic in a component, hook or adapter: decoding a native result, deciding a registration or enrollment transition, retrying, merging or filtering mail state. That logic belongs in a `mail-core` store so both hosts and its tests share it.
- A store read any way other than `useSyncExternalStore(store.subscribe, store.getSnapshot)`, or store state copied into `useState` and kept in step by an effect. The copy goes stale between the event and the effect.
- A native module result used in the host before the shared store decodes it. The adapter passes the raw result through; see `src/private-storage.ts`.
- Effect imported into a component or hook. React code is plain TypeScript consuming stores.
- An import of `@private-email/convex`, `@private-email/mail-test-harness`, a `mail-core` path outside its `exports`, or the other host's source.
- The same logic added to both hosts in one change. Two copies drift; move it to `mail-core` unless it depends on a host API.

#### React correctness

- `DraftList.compose` guarding only `useLeaveComposer.leave` rather than the
  whole New Message action. Acquire its event-facing latch before awaiting
  leaving, hold it through `store.create`, and keep the visible button disabled
  until refusal or completion releases it. A second press after leaving settles
  but while persistence is pending otherwise creates another blank Draft. Check
  refused leaving, failed storage and owner/unmount changes without resetting
  an in-flight latch merely because the component rendered again.

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

- `Editor` suppressing autosave during explicit Discard without retaining the
  latest authored payload and restoring it when deletion fails or rejects.
  Text and Undo events can still arrive while storage is pending; trace rendered
  history, the authored ref and subsequent Close/reopen, or visible accepted edits
  disappear. Cancelled confirmation must leave saving enabled; a completed own
  discard must suppress queued callbacks so they cannot recreate its Draft.

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
- Per-row work in the Inbox `FlatList` that grows with the mailbox: an unstable `keyExtractor`, a row that subscribes to the whole store, or sorting and filtering repeated on every render.
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
- Selection held anywhere but its owner: route parameters on mobile, the window on Mac. A Mac window opened after another must start with no selection, and a read/unread change must reach every window without changing any selection.
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

#### Platform behavior

- A pressable without an accessible role and name, text that does not scale with Dynamic Type, a color taken from a literal rather than the light/dark tokens in `mail-core`'s `theme`, or selection and focus shown by color alone.
- A component library, navigation library or native module added to either host. Mobile uses Router's split view and React Native `StyleSheet`; the Mac host admits `react-native-webview` only, and adding another requires updating `apps/macos/scripts/verify-bundle.ts`.
- Mac window identity, menu routing, focus or application lifetime handled in JavaScript. AppKit owns them; closing the last window keeps the app running.
- A route, deep link or window identifier used before validation, or used to select a message in a store that has not confirmed it exists; the unavailable route must render.
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

#### Bundle and workspace boundary

- A dependency declared with a literal version rather than its `catalog:` entry, taken from the other host's catalog, or added to `dependencies` when only tests use it.
- A change to a host's `scripts/verify-bundle.ts` (`apps/mobile/scripts/verify-bundle.ts`, `apps/macos/scripts/verify-bundle.ts`) that removes or loosens an assertion: the renderer inventory, the stale shared-source comparison, the rejection of the other renderer, Expo, React DOM or backend code in the Mac bundle, or the autolinking list. Version declarations do not prove what the bundle contains; these checks do.

#### Tests in the same change

Apply `docs/agents/testing.md`'s admission and proportionate-verification policy: existing meaningful coverage may suffice; document unavailable automation or protected/native evidence with its required follow-up. The cases below identify missing evidence for a named risk, not a requirement to add a test for every edit.

- A changed journey with no component integration test under the host's `test/` that drives the real `mail-core` store with a substituted native boundary. A rendered component test is not native E2E evidence; a Hermes export proves the bundle, not the behavior.
- A test that mocks the store or asserts a callback was called rather than the rendered outcome.
- Unavailable native evidence reported as passing rather than deferred.

#### Leave to tooling

Hooks-rule violations (including synchronous state setters in effects and nested component definitions), formatting, unused exports, type errors and Effect import style are covered by oxlint, oxfmt, Fallow and the type checker. Inline styles are normal in React Native; flag a style only for a behavior defect.
