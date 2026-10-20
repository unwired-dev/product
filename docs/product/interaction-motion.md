# Interaction motion

Status: goals and approach confirmed by the owner. Implementation and motion
design approval remain tracked separately; this document does not establish
completed implementation or approved visual changes.

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

## Proposed next steps

1. Inventory controls and user-initiated content changes in both clients.
2. Inspect the matching Figma frames and define representative motion examples,
   including Reduced Motion, interrupted actions, failure and Undo. Reconcile
   existing feature-specific requirements and obtain design approval.
3. Implement approved defaults with the supported tools of each host. Share
   motion values only where both hosts need them; native transitions retain
   their platform defaults.
4. Complete the inventory and verify the affected journeys on iPhone, iPad and
   Mac. Record unavailable native checks as deferred rather than passed.

Exact motion values, rollout slices and any justified custom-control exceptions
remain to be established through inventory and design. No new motion dependency
or universal animation wrapper is selected by this proposal.

## Tracked gaps and existing ownership

Static source inventory was taken at `59c06716a52d9c898dc34292e7f9bf4a0569a7be`.
The paths below are relative to each host's `src/` directory in
[`apps/mobile`](../../apps/mobile) and [`apps/macos`](../../apps/macos), unless
qualified. This groups the inspected interaction families; it is not a completed
per-control ledger or native interaction qualification.

| Interaction family                          | Source entry points                                                                                                                                                                                                                                         | Current evidence and gap owner                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Buttons and toolbar actions                 | `design.tsx`, `action.tsx`; mobile `organize-action-button.tsx`                                                                                                                                                                                             | Toolbar buttons and quiet Buttons have immediate pressed feedback. Accent Buttons retain their idle fill while pressed; reader Action also lacks pressed-dependent styling. [#1090](https://github.com/unwired-dev/product/issues/1090) audits retained mail-specific gaps after native selection.                                                                                                                  |
| Message rows, mailbox navigation and search | `inbox-rows.tsx`, `sidebar.tsx`, `inbox-bar.tsx`; mobile `inbox-heading.tsx`, `inbox-search.tsx`                                                                                                                                                            | Rows already highlight press, selection and focus. Existing native migration [#1055](https://github.com/unwired-dev/product/issues/1055) and retained-control [#1090](https://github.com/unwired-dev/product/issues/1090) own applicable coverage. Static highlights can already be sufficient.                                                                                                                     |
| Settings, accounts and setup                | `settings.tsx`, `account-settings.tsx`, `onboarding.tsx`, `registration-onboarding.tsx`, `registration-gate.tsx`, `imap-setup.tsx`, `language-selector.tsx`, `trusted-devices.tsx`, `error-reporting.tsx`, `mail-assistance.tsx`; mobile `account-page.tsx` | Mixed native inputs/switches/dialogs and custom actions. Standard control migrations remain [#1057](https://github.com/unwired-dev/product/issues/1057) and [#1058](https://github.com/unwired-dev/product/issues/1058); [#1090](https://github.com/unwired-dev/product/issues/1090) covers retained custom feedback.                                                                                               |
| Reader, attachments and assistance          | `message-detail.tsx`, `message-body.tsx`, `remote-content.tsx`, `translation.tsx`, `draft-assistance.tsx`, `organize.tsx`; mobile `reader-chrome.tsx`                                                                                                       | Native context menus and activity indicators already exist. [#1090](https://github.com/unwired-dev/product/issues/1090) covers retained controls; [#1092](https://github.com/unwired-dev/product/issues/1092) audits outcome feedback.                                                                                                                                                                              |
| Composer and Outbox                         | `composer.tsx`, `composer-controls.tsx`, `evaluation-composer.tsx`, `evaluation-composer-controls.tsx`, `outbox.tsx`                                                                                                                                        | Native editing, custom controls and existing menu motion coexist. Native menus remain [#1075](https://github.com/unwired-dev/product/issues/1075) and [#1076](https://github.com/unwired-dev/product/issues/1076). [#1090](https://github.com/unwired-dev/product/issues/1090) and [#1092](https://github.com/unwired-dev/product/issues/1092) cover remaining feedback.                                            |
| Navigation, menus and presentations         | `command-palette.tsx`, `design.tsx`; mobile `inbox-filters.tsx`, `reply-sheet.tsx`, `move-sheet.tsx`; mobile `../app/_layout.tsx`; Mac `window.tsx`                                                                                                         | Existing menu helpers respect Reduce Motion. [#1046](https://github.com/unwired-dev/product/issues/1046) owns palette/Back/menu repair and its separate design prerequisite. Native navigation and presenters remain with [#1053](https://github.com/unwired-dev/product/issues/1053), [#1073](https://github.com/unwired-dev/product/issues/1073) and [#1074](https://github.com/unwired-dev/product/issues/1074). |
| User-initiated content changes              | `inbox.tsx`, `inbox-rows.tsx`, `organize.tsx`; mobile `inbox-filters.tsx`                                                                                                                                                                                   | Lists render changed sections directly; no explicit list transition mechanism or action-versus-sync provenance was found in this presentation path. [#1091](https://github.com/unwired-dev/product/issues/1091) owns approved continuity for existing actions, filtering and Undo.                                                                                                                                  |
| Pending work, failure and recovery          | `organize.tsx`, `outbox.tsx`, `composer.tsx`, account/connection and assistance entry points above                                                                                                                                                          | Notices, Undo, activity indicators and announcements already exist. [#1092](https://github.com/unwired-dev/product/issues/1092) audits remaining gaps. [#981](https://github.com/unwired-dev/product/issues/981) owns blinking autosave feedback; [#983](https://github.com/unwired-dev/product/issues/983) owns stuck delivery.                                                                                    |

[#1089](https://github.com/unwired-dev/product/issues/1089) owns the complete
per-control ledger, representative Figma motion specification and owner approval.
It is a native GitHub blocking dependency of #1090, #1091 and #1092. Preparing
design does not authorize UI implementation before approval. Existing #1046's
requested designer and approval remain separate.

The existing native migration epic #1053 owns standard control replacement and
superseded motion cleanup. #849 owns keyboard/bulk-action capability; the new
motion slices do not add bulk actions or gestures. Native accessibility and
responsiveness qualification remains with #626, using the visual evidence work
in #1061 through #1065 where applicable. A static inventory, a screenshot or
component tests alone cannot establish native gesture, focus or motion quality.

No app was run for this inventory. Each owner must verify its remaining gaps
against the current native implementation and update the ledger with evidence.

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
