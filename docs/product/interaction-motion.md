# Interaction motion

Status: goals and approach confirmed by the owner. The per-control
[coverage ledger](#coverage-ledger) is complete from static source inspection. The
[proposed motion specification](#proposed-motion-specification) awaits owner
approval; until then it authorizes no UI implementation. This document does not
establish completed implementation or native qualification.

## Agreed goals

- Cover both maintained clients: Expo on iPhone and iPad, and React Native macOS.
  The Swift prototype is outside this scope.
- Developers receive appropriate feedback by using the approved controls,
  without adding animation code at each call site.
- The Apple/native layer owns native controls' and presenters' standard
  feedback, transitions and gestures. The TypeScript/React Native layer invokes
  their supported APIs without duplicating that behavior. Follow
  [native component selection](../agents/native-components.md).
- The TypeScript/React Native layer owns application-specific control feedback
  and the intent of designed content transitions. Approved controls provide
  consistent feedback by default; native presenters retain their standard motion.
- Routine motion makes mail feel immediate and predictable. Stronger motion
  is reserved for changes that need explanation.
- Every action has clear feedback. An immediate highlight or state change can
  provide that feedback without movement.
- Respect Reduce Motion, allow interruption and never delay an action until
  an animation finishes.
- Share motion principles across clients while preserving platform behavior.
- Cover control feedback and the resulting content transition, including
  user-initiated removal and filtering. Design transitions per action; a render
  by itself does not trigger motion.
- Keep background synchronization visually quiet. Avoid repeated entrance
  animations for synchronized messages and preserve reading position and
  selection as content updates.
- Distinguish activation from success. Press feedback acknowledges input;
  pending feedback appears only while work remains pending. Success, failure
  and Undo feedback follow the actual action state. Animation never implies
  that an operation succeeded.
- Keep custom control feedback restrained. Use appropriate pressed, hover,
  focus and selection states. Reserve movement for changes it helps explain;
  do not apply a universal shrink or bounce effect.
- Complete coverage is an acceptance requirement. Inventory interactive controls
  in both maintained clients and classify each as native or application-specific.
  Shared buttons alone do not establish coverage of standalone controls.
- Use suitable native controls and put application-specific feedback defaults
  in approved components so their callers inherit that feedback.
- Verify touch, pointer, keyboard, cancellation and Reduce Motion on the
  applicable platforms.

## Next steps

1. Obtain owner approval of the
   [proposed motion specification](#proposed-motion-specification) and link the
   approved Figma nodes here.
2. After approval, implement approved defaults with the supported tools of each
   host through the follow-up owners. Share motion values only where both hosts
   need them; native transitions retain their platform defaults.
3. Verify the affected journeys on iPhone, iPad and Mac and update the ledger
   with evidence. Record unavailable native checks as deferred rather than passed.

No new motion dependency or universal animation wrapper is selected.

## Coverage ledger

Static source inventory was taken at `4b9a4b8ddb0e236932fd73a7b15f2af5fe8402d4`.
Paths are relative to each host's `src/` directory in
[`apps/mobile`](../../apps/mobile) and [`apps/macos`](../../apps/macos); "both"
means both hosts have a file of that name. No app was run, so every row's
verification status is **static only**: native press, focus, gesture and motion
quality stay unqualified until their owner records native evidence. Native rows
are qualified with [#626](https://github.com/unwired-dev/product/issues/626).

Each row is classified as:

- **Native**: a system control or presenter owns its feedback and motion.
- **Sufficient**: existing static feedback already meets the goals; its owner
  only verifies it natively.
- **Gap**: a retained application-specific control or transition lacks feedback.
- **Migration**: a native migration replaces the custom implementation; do not
  decorate it first.

Inventory facts that apply throughout: neither client has hover feedback,
haptics or `LayoutAnimation`. The only custom motion is the shared menu motion
(`useMenuMotion` on mobile and `MenuPresence` on the Mac, both in `design.tsx`),
the Filters popover's Reanimated fade (`inbox-filters.tsx`) and the onboarding
Restoring screen (`onboarding.tsx`).

### Controls

| Family and source                                                                                              | Hosts  | Ownership                                              | Current feedback                                                                                                                       | Classification and gap                                                                            | Owner                                                                                                                                                                                                   |
| -------------------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Push buttons: `Button` in `design.tsx` (Retry, Allow Access, Send, Discard, Translate, Rewrite, setup buttons) | both   | Custom                                                 | Quiet: pressed fill. Accent: idle fill while pressed. Disabled 50%. No focus ring                                                      | Gap: accent pressed state, focus ring                                                             | [#1090](https://github.com/unwired-dev/product/issues/1090)                                                                                                                                             |
| `ToolbarButton` in `design.tsx` (reader actions, composer formatting, Undo/Redo, attach)                       | both   | Custom; on mobile inside interactive Liquid Glass      | Pressed, expanded or selected fill; 2pt focus ring; disabled 40%                                                                       | Mac: Sufficient. Mobile: Gap, the fill stacks on the native glass press                           | #1090; glass bindings [#1121](https://github.com/unwired-dev/product/issues/1121)                                                                                                                       |
| Reader text actions: `Action` in `action.tsx` (Summarize, Translate, Load Images, attachment actions)          | both   | Custom                                                 | None                                                                                                                                   | Gap: pressed, focus and disabled states                                                           | #1090                                                                                                                                                                                                   |
| Composer text actions: `Action` in `composer.tsx` (Cc/Bcc, asset Retry, Outbox Undo/Edit/Check)                | both   | Custom                                                 | Disabled ink only                                                                                                                      | Gap: pressed and focus states; second component with the same role as `action.tsx`                | #1090                                                                                                                                                                                                   |
| Organize actions: `ActionButton` in `organize.tsx` (Mac) and `organize-action-button.tsx` (mobile)             | both   | Custom                                                 | Pressed fill, focus ring, checkmark                                                                                                    | Sufficient                                                                                        | #1090 verifies                                                                                                                                                                                          |
| Message rows in `inbox-rows.tsx`                                                                               | both   | Custom                                                 | Pressed fill, accent selected fill, focus ring; selection changes without transition                                                   | Sufficient                                                                                        | #1090 verifies                                                                                                                                                                                          |
| Draft rows: `DraftRow` in `composer.tsx`                                                                       | both   | Custom                                                 | Selected fill only                                                                                                                     | Gap: pressed and focus states                                                                     | #1090                                                                                                                                                                                                   |
| Outbox rows in `outbox.tsx`                                                                                    | both   | Custom row with composer text actions                  | Status is a polite live region; Checking is a label change                                                                             | Gap only through the composer text actions; pending state audited by #1092                        | #1090, [#1092](https://github.com/unwired-dev/product/issues/1092), [#983](https://github.com/unwired-dev/product/issues/983)                                                                           |
| Sidebar and Mailboxes items in `sidebar.tsx`                                                                   | both   | Custom                                                 | Pressed or selected fill; bold selection; Mac focus ring                                                                               | Sufficient                                                                                        | #1090 verifies                                                                                                                                                                                          |
| Profile Switcher in `sidebar.tsx`                                                                              | both   | Native menu; Mac trigger is custom                     | Mobile: system button. Mac trigger: static fill, no pressed or focus state                                                             | Mac: Migration to a provided pop-up button                                                        | [#1058](https://github.com/unwired-dev/product/issues/1058)                                                                                                                                             |
| Mac pop-up triggers: `PopUp` in `composer-controls.tsx` (From, Text Style, Move, Writing Tools, settings)      | Mac    | Native menu; custom trigger                            | Static fill; not focusable                                                                                                             | Migration to provided pop-up buttons                                                              | #1058                                                                                                                                                                                                   |
| Mobile in-flow menus: `PopUp` and `MenuItem` in `composer-controls.tsx`, Format panel                          | mobile | Custom menu with the shared menu motion                | 200 ms in, 150 ms out; no pressed state on trigger or items                                                                            | Migration to native menus                                                                         | [#1075](https://github.com/unwired-dev/product/issues/1075), [#1057](https://github.com/unwired-dev/product/issues/1057)                                                                                |
| Context menus: `ContextMenu` in `design.tsx` (rows, metadata, links, attachments, asset chips)                 | both   | Native                                                 | System                                                                                                                                 | Native                                                                                            | —                                                                                                                                                                                                       |
| Alerts and sheets: `Alert.alert`, `Alert.prompt`; Mac `askInSheet` in `design.tsx`                             | both   | Native                                                 | System                                                                                                                                 | Native; destructive button marking is [#1225](https://github.com/unwired-dev/product/issues/1225) | —                                                                                                                                                                                                       |
| Gmail Labels panel and evaluation format bar: `GlassPanel` and `MenuPresence` in `design.tsx`                  | Mac    | Custom presentation                                    | Fade with 0.95 scale, 200 ms in, 150 ms out; Reduce Motion keeps the fade                                                              | Migration; motion removal with the last consumer                                                  | #1058, [#1059](https://github.com/unwired-dev/product/issues/1059)                                                                                                                                      |
| Reader toolbar panels: `GlassPanel` in `organize.tsx`                                                          | mobile | Custom presentation                                    | Shared menu motion; panel content switches without transition                                                                          | Migration                                                                                         | [#1056](https://github.com/unwired-dev/product/issues/1056), #1059                                                                                                                                      |
| Move and Reply sheets: `move-sheet.tsx`, `reply-sheet.tsx`                                                     | iPhone | Custom Modal, scrim and grow motion                    | 300 ms grow in, 150 ms out; Reduce Motion fades                                                                                        | Migration; lifecycle repair with #1046                                                            | [#1074](https://github.com/unwired-dev/product/issues/1074), [#1118](https://github.com/unwired-dev/product/issues/1118), [#1046](https://github.com/unwired-dev/product/issues/1046)                   |
| Filters sheet and popover: `inbox-filters.tsx`                                                                 | mobile | Custom Modal and scrim; popover uses a Reanimated fade | Sheet fades; popover fades in with no exit; apply control has no pressed state                                                         | Migration; keep the popover's no-exit rule                                                        | [#1119](https://github.com/unwired-dev/product/issues/1119)                                                                                                                                             |
| Link confirmation in `message-body.tsx`                                                                        | both   | Custom overlay                                         | Appears instantly; focus ring only                                                                                                     | Migration to a native alert                                                                       | Mac [#1130](https://github.com/unwired-dev/product/issues/1130); mobile #1056                                                                                                                           |
| Trusted Device removal confirmation in `trusted-devices.tsx`                                                   | mobile | Custom Modal                                           | Appears instantly; no pressed state                                                                                                    | Migration to a native alert                                                                       | [#1120](https://github.com/unwired-dev/product/issues/1120)                                                                                                                                             |
| Command Palette in `command-palette.tsx` (scrim, field, rows, Back, Cancel; mobile header swipe)               | both   | Custom presentation                                    | Mounts and unmounts instantly; rows, Back and Cancel have no pressed state; the swipe does not track                                   | Gap: entry and exit motion and swipe repair; row press states                                     | #1046; row press states #1090                                                                                                                                                                           |
| Navigation: split columns in `../app/_layout.tsx`, reader Back in `reader-chrome.tsx`, iPhone Settings stack   | mobile | Native                                                 | System transitions and edge swipe                                                                                                      | Native                                                                                            | —                                                                                                                                                                                                       |
| iPhone Inbox Back and search scope in `inbox-heading.tsx`; iPad Settings and Privacy overlays                  | mobile | Custom                                                 | Non-interactive glass Back; scope selection snaps; iPad overlays appear instantly                                                      | Migration to native navigation, headers and search                                                | [#1055](https://github.com/unwired-dev/product/issues/1055)                                                                                                                                             |
| Floating bar in `inbox-bar.tsx` (New Message, Search, Filter)                                                  | mobile | Custom inside interactive Liquid Glass                 | Native glass press; the Filter summary resizes the pill without transition                                                             | Sufficient                                                                                        | #1090 verifies                                                                                                                                                                                          |
| Mac bar controls: New Message in `inbox-bar.tsx`, sidebar toggle in `window.tsx`                               | Mac    | Custom                                                 | Focus ring only                                                                                                                        | Gap: pressed state                                                                                | #1090                                                                                                                                                                                                   |
| Text fields (search, composer, settings, palette)                                                              | both   | Native                                                 | System                                                                                                                                 | Native                                                                                            | —                                                                                                                                                                                                       |
| Switches (notifications, Mail Assistance, error reporting, Filters)                                            | both   | Native                                                 | System; mobile Mail Assistance wraps its switch in a custom pressable                                                                  | Native; wrapper Gap                                                                               | #1090                                                                                                                                                                                                   |
| Choose-one options: `language-selector.tsx`, `translation.tsx`; mobile `imap-setup.tsx`, `remote-content.tsx`  | both   | Custom                                                 | Selected border or fill only                                                                                                           | Migration to native pickers or pop-ups                                                            | Mac [#1196](https://github.com/unwired-dev/product/issues/1196); mobile [#1122](https://github.com/unwired-dev/product/issues/1122), [#1123](https://github.com/unwired-dev/product/issues/1123), #1057 |
| Mobile composer header: Close and Send in `composer.tsx`                                                       | mobile | Custom; Close uses non-interactive glass               | No pressed or disabled styling; Send keeps its fill                                                                                    | Gap                                                                                               | #1090                                                                                                                                                                                                   |
| Composer inline controls: recipient tokens, quoted text, Cc/Bcc in `composer.tsx`; reader quoted text          | both   | Custom                                                 | None                                                                                                                                   | Gap: pressed and focus states                                                                     | #1090                                                                                                                                                                                                   |
| Settings navigation and push buttons in `settings.tsx`                                                         | both   | Custom                                                 | Pressed or selected fill; Mac focus ring; busy dims to 40%                                                                             | Sufficient; busy feedback audited by #1092                                                        | #1090 verifies, #1092                                                                                                                                                                                   |
| Mail Profile rows, Add and Remove in `profile-settings.tsx`                                                    | both   | Custom                                                 | Rows: pressed fill. Selected Profile has no visual state. Add and Remove: none                                                         | Gap                                                                                               | #1090                                                                                                                                                                                                   |
| Error reporting entry and actions in `error-reporting.tsx`                                                     | both   | Custom                                                 | Actions: pressed fill, disabled. Entry: none                                                                                           | Gap: entry pressed state                                                                          | #1090                                                                                                                                                                                                   |
| Onboarding: `OnboardingAction`, `ProviderRow`, Privacy link and Back in `onboarding.tsx`; mobile Open Inbox    | both   | Custom; Mac Sign in with Apple is native               | Brand and Apple fills unchanged while pressed; ProviderRow pressed fill; no focus rings                                                | Gap                                                                                               | #1090                                                                                                                                                                                                   |
| Standalone links: online search (`inbox.tsx`, `inbox-search.tsx`), reader retry, message link list             | both   | Custom                                                 | None, or focus ring only                                                                                                               | Gap: pressed state                                                                                | #1090                                                                                                                                                                                                   |
| Activity indicators                                                                                            | both   | Native                                                 | Spinner; busy buttons only disable                                                                                                     | Native; pending audit                                                                             | #1092                                                                                                                                                                                                   |
| Pull to refresh in `inbox.tsx`                                                                                 | mobile | Native                                                 | System refresh control                                                                                                                 | Native                                                                                            | —                                                                                                                                                                                                       |
| Mac menu bar and windows: `AppDelegate.mm`                                                                     | Mac    | Native                                                 | System                                                                                                                                 | Native                                                                                            | —                                                                                                                                                                                                       |
| Onboarding Restoring motion in `onboarding.tsx`                                                                | both   | Custom                                                 | Seal breathing and a status fade. Mobile stops breathing under Reduce Motion; the Mac reads the setting once and ignores later changes | Gap on the Mac: follow Reduce Motion changes                                                      | #1090                                                                                                                                                                                                   |

### User-initiated content changes

| Change                                                                      | Current behavior                                                                                      | Classification and owner                                                    |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Archive, Trash, Spam and Move from rows, reader, panels, palette and sheets | The row disappears in an instant re-render; the reader closes; a notice and an announcement appear    | Gap: [#1091](https://github.com/unwired-dev/product/issues/1091)            |
| Undo, and Retry or Discard of a blocked change                              | The row reappears in an instant re-render; the notice is replaced                                     | Gap: #1091; outcome feedback #1092                                          |
| Search, Filter, search scope, mailbox, folder and Profile changes           | The list is replaced in an instant re-render                                                          | Sufficient under the specification (no row motion); #1091 verifies          |
| Background synchronization and pull to refresh                              | The list updates in place; skeleton rows while a folder first syncs; no action-versus-sync provenance | Sufficient if it stays quiet; #1091 verifies reading position and selection |
| Opening a message and changing the selection                                | Native column transition on iPhone; instant swap on iPad and Mac; bodies reveal per the reader guide  | Native or Sufficient                                                        |
| Opening, closing and expanding the composer                                 | An overlay mounts and unmounts instantly                                                              | Migration: mobile #1056, Mac #1058                                          |
| Send, Reply and Forward preparation, Outbox Undo and Edit                   | Controls disable; a text line or Outbox row appears; Send shows no pending state                      | Gap: #1092                                                                  |
| Summary, translation, assistance, Load Images, attachments                  | Activity indicator and text, then an instant swap                                                     | #1092 audits                                                                |
| Command Palette open, close and pages                                       | Instant                                                                                               | Gap: #1046                                                                  |
| iPad and Mac Settings destinations, onboarding steps                        | Instant content swap                                                                                  | Sufficient                                                                  |
| Mac sidebar show and hide in `window.tsx`                                   | Instant mount and unmount                                                                             | Migration: #1058                                                            |
| Notices (synchronization, authorization, storage, organize outcomes)        | Mount instantly as polite live regions                                                                | Sufficient                                                                  |

## Proposed motion specification

Proposed for owner review on 24 October 2026; **not approved**. It specifies only
missing or changed feedback. Each Figma section shows Light and Dark, and its
Archive frames are linked as a click-through prototype:

- [Mac](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=481-57440)
- [iPad](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=483-61996)
- [iPhone](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=483-150893)

Timing reuses the existing menu motion: 200 ms entry, 150 ms exit, ease-out
`cubic-bezier(0.23, 1, 0.32, 1)`. No haptics, bounce, shrink or hover effects.

**Control feedback** (#1090):

- Pressed appears on touch-down or mouse-down and clears on release or
  cancellation, including dragging away. It is instant, without fade or
  movement.
- Filled buttons (accent, Brand, Send) show their fill at 80% opacity while
  pressed. Quiet buttons, text actions, toolbar buttons and rows use
  `accent/selection-subtle`.
- Keyboard focus is a 2pt `accent/ink` ring on every focusable custom control.
  Disabled custom controls dim to 40%.
- Controls inside interactive Liquid Glass keep only the native glass press,
  with no added fill. Glass circles such as Back, Close and Open Inbox become
  interactive glass.
- Pointer hover adds nothing to custom controls; native controls keep their
  system hover.

**Removal and Undo** (#1091):

- The action runs on press; the reader closes at once, and on iPhone the native
  Back returns to the list first.
- The leaving row fades and collapses over 200 ms while the rows below move up
  with it. The Undo notice appears with the exit.
- Undo restores the row in place with the reverse motion over 200 ms and does
  not select it.
- Reduce Motion: no collapse, slide or scale. A leaving row is removed at once,
  and a restored row fades in over 150 ms.
- Interruption: a new action, Undo, scroll or selection takes effect
  immediately. A leaving row finishes at once, and Undo reverses from the
  current height.
- Failure: a change that is refused or discarded returns its row with the Undo
  motion and keeps the existing Retry and Discard notice. Nothing implies
  success before the change is saved.

**Lists and outcomes** (#1091, #1092):

- Background synchronization and pull to refresh never animate rows. The
  topmost visible row and the selection stay in place.
- Search, Filter, search scope and mailbox or Profile changes replace the list
  without row motion. The Filters popover keeps its fade-in with no exit
  animation.
- Pending feedback appears only while work is pending. There is no success
  animation; outcome notices keep their once-only announcements.

Command Palette entry and exit, Back completion and the Reply and Move lifecycle
remain with #1046 and its own design approval. Native migrations remain with
[#1053](https://github.com/unwired-dev/product/issues/1053) and its children;
[#849](https://github.com/unwired-dev/product/issues/849) owns keyboard and
bulk-action capability, and [#981](https://github.com/unwired-dev/product/issues/981)
owns blinking autosave feedback. [#1089](https://github.com/unwired-dev/product/issues/1089)
owns this ledger, the specification and its approval, and is a native GitHub
blocking dependency of #1090, #1091 and #1092. Native accessibility and
responsiveness qualification remains with #626, using the visual evidence work in
#1061 through #1065 where applicable.

## Existing requirements

[DESIGN.md](../../DESIGN.md) assigns standard behavior and motion to native
controls. [Inbox requirements](../gmail-inbox.md#filtering-the-inbox) include a
Filter popover that fades in and closes without an exit animation. The reader
action requirements in that same guide include anchored Reply and Move
transitions and fade-only alternatives under Reduce Motion. Reconcile each
affected requirement explicitly during design rather than replacing it with a
blanket animation rule.

Visible changes beyond the existing frames follow the
[design approval workflow](../agents/implementation-review.md#design-approval)
before UI implementation.
