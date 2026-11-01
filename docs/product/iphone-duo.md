# iPhone Duo readiness

Confirmed requirements from the owner's 2026-11-01 scope interview and ticket
review. [Tracking issue #1650](https://github.com/unwired-dev/product/issues/1650)
owns implementation completion. This document defines target behavior, not
implemented features, UI design approval, or passing qualification.

## Scope and delivery

- Deliver an optimized mail experience on iPhone Duo, alongside the existing
  [power-user launch](power-user-launch.md), with a separate Duo readiness gate.
  Duo work does not block every existing launch issue.
- Extend the shared adaptive iPhone and iPad interface. Choose columns and
  controls from available space and native layout behavior, rather than treating
  an iPhone as permanently compact or introducing separate Duo navigation.
- Keep one [Mail Profile Window](../domain/identity.md#language). Independent app windows remain under
  [#1200](https://github.com/unwired-dev/product/issues/1200).
- Include dedicated tabletop reading and replying layouts.
- Investigate simultaneous inner and outer display mail through supported public
  APIs. This feasibility issue does not block the optimized Duo release. Its
  implementation requires a supported non-camera API and a later agreement on
  the workflow and privacy rules. Do not start a camera session to expose mail
  on the outer display.
- Preserve the existing provider, Profile, Draft, Outbox, privacy, and assistance
  requirements. This work adds no provider, sign-in, or assistance scope.

## Displays and tabletop behavior

On the outer display, preserve compact navigation and access to all mail actions.
On the inner display, expose useful mail columns when space permits. Retain the
same selected Thread and current task as the device folds, unfolds, or rotates.
Split View with another app must remain usable in either app position.

In tabletop reading, show the selected Thread above the fold and the message list
below. In tabletop replying, show the referenced Thread above and the existing
Draft below. Keep essential content and controls clear of the folding region.
When no Thread is selected or a new Draft has no referenced Thread, retain the
existing empty or compose state without selecting mail or inventing context.

Folding rearranges the current window's layout. It does not create or switch a Draft,
save or send mail, grant content access, or start assistance. Leaving tabletop
returns the same window to the layout appropriate for the available space.
When space is constrained by multitasking, the keyboard, or accessibility text
sizes, keep the active task and actions usable without forcing both panes to fit.

New appearance and tabletop states require Light and Dark Figma designs and owner
approval before dependent UI implementation, under the existing
[design approval policy](../agents/implementation-review.md#design-approval).
The existing visual system and native controls remain the starting point.

## Continuity and lifecycle

Display and layout transitions preserve the current Mail Profile, mailbox,
search query and filters, selected Thread, and useful list and reader positions.
Preserve the same Draft, authored content, unfinished recipient entry, attachments,
editor selection, Undo history, and editing focus. An open Link Editor or
Generate a Draft prompt retains its entered values if its presentation changes.
Existing [#1648](https://github.com/unwired-dev/product/issues/1648) owns those
known presenter-state losses.

Apply these requirements on first use, after relaunch, and when upgrading an
existing installation. A display change does not create a Product Account,
Profile, Mailbox Connection, or additional Draft. Saved state keeps its current
ownership and privacy boundaries.

Folding during a pending save, send, attachment import, synchronization, or
assistance request does not restart or duplicate that operation. Existing Cancel,
Retry, failure, and Undo behavior remains available. Results that arrive after
the person changes Thread, Draft, or Profile follow the existing destination and
acceptance rules; a layout change does not authorize applying them elsewhere.

Offline reading and editing retain the same capabilities and limitations through
display changes. Restoring connectivity does not submit mail or accept assistance
because a fold occurred. Closing, discarding, or removing content continues to
follow the existing mail contracts and exit guards.

## Controls and accessibility

Preserve Back, Close, Compose, Send, search, filtering, and reader actions when
native bars change between horizontal and vertical presentation or overflow.
Native containers own their standard navigation, presentations, and transitions.
The app owns the mail state and actions these transitions preserve, including the
current Mail Profile, selected Thread, Draft, and pending operations. Follow
[native component selection](../agents/native-components.md#choose-the-provided-implementation)
and record a concrete supported-API gap before retaining a custom interaction.

Handle left and right safe areas, folding regions, active camera occlusions, and
keyboard geometry. Menus, sheets, popovers, assistance panels, and attachment
previews remain visible and usable when their anchor or available region changes.

Qualify Dynamic Type, VoiceOver, hardware-keyboard focus and shortcuts, Reduce
Motion, Reduce Transparency, and long localized strings in both appearances.
Keep all actions available when a layout collapses. No fold-specific permission
or additional setup is required for the shared adaptive interface.

## Build and qualification gate

Complete the [compatible library update #1651](https://github.com/unwired-dev/product/issues/1651)
before the [Duo build qualification #1652](https://github.com/unwired-dev/product/issues/1652).
Update the supported Expo and React Native package set and required peers
together, preserving the separate Mac compatibility boundary. Verify the
existing iPhone and iPad mail journey on that baseline before Duo-specific work.

Qualify a build linked against the iOS 27.1 SDK or later. Verify the generated
scene lifecycle, cold and warm links, sign-in returns, notifications, and
background restoration with the selected compatible Expo stack. Building with
that SDK does not require raising the current minimum OS version by itself.

[Expo's Duo guide](https://expo.dev/blog/supporting-iphone-duo) documents an SDK 58
path. Evaluate and qualify that supported path with the existing native host and
its dependencies; [the mobile catalog](../../pnpm-workspace.yaml) owns selected
package versions. Do not infer production readiness from an experimental
navigation example or assume scene lifecycle support supplies independent windows.

Record app build, linked SDK, package versions, runtime, device, appearance, pose,
and input settings with evidence under the
[readiness gate #1659](https://github.com/unwired-dev/product/issues/1659).
Cover closed, partially folded, flat, book,
tabletop, and tent use; both orientations; multitasking in both app positions;
and transitions while reading, searching, composing, completing setup, editing
Settings, or presenting a panel. Include offline work, cancellation, retry, and
late results, preserving the lifecycle and ownership requirements above.
Include ordinary iPhone and iPad regression checks when shared layout changes.

Extend existing native journeys and evidence tooling. Component tests may prove
retained application state, but do not qualify folds, native bars, focus, or
gestures. Simulator and physical-device evidence remain distinct. Hardware and
accessibility checks unavailable in Device Hub stay required before declaring
Duo readiness, under the [native validation policy](../agents/native-validation.md).
Keep real provider evidence distinct from Mock Mail Sessions.

Before advertising support, record the completed gate and provide the appropriate
Duo store assets through the existing
[release issue #669](https://github.com/unwired-dev/product/issues/669). Recheck
current App Store requirements at release time. A store badge or screenshot does
not establish successful qualification.

## Primary references

- [Apple preparation steps](https://developer.apple.com/iphone-duo/prepare/)
- [Apple Duo interface guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [Apple displays and scenes session](https://developer.apple.com/videos/play/tech-talks/111464/)
- [Expo Duo support](https://expo.dev/blog/supporting-iphone-duo)
- [React Native 0.88 scene limitations](https://reactnative.dev/blog/2026/10/19/react-native-0.88)
