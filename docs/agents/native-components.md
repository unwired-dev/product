# Native component selection

Use native, React Native and Expo-provided components for standard platform
interactions. This applies to new UI and changes to existing UI in the maintained
mobile and Mac clients. An existing custom implementation is migration work,
not a precedent to copy.

## Choose the provided implementation

1. Check the public components and APIs supported by the host's installed React
   Native, Expo and navigation versions. Use the provided control or presenter
   directly when it meets the product requirement. Prefer the complete native
   interaction over recreating its appearance with `View`, `Pressable` and `Text`.
2. Compose application-specific mail content with React Native primitives.
   Keep domain state and actions in application code; let the native component
   own its standard interaction, focus, selection, dismissal and transition.
3. If the host does not expose a required platform capability, check maintained
   compatible packages before writing a minimal adapter to the system control.
   Expo components belong only in supported hosts; the Mac client keeps its
   React Native macOS/AppKit dependency boundary.

Apply this order before reusing a house component or following a skill's generic
reuse advice. A styling or localization wrapper is useful only when it removes
real repetition without duplicating the underlying component's API or lifecycle.

Standard navigation, Back gestures, headers, toolbars, search fields, menus,
dialogs, sheets, popovers, buttons, switches and pickers follow this rule. Use
public framework composition rather than creating another navigation adapter,
presentation state machine or shared widget framework. A dependency upgrade
must preserve the host's supported compatibility set; a fork or experimental API
is not the default shortcut to a missing control.

## Native behavior and design

Let the native presenter own its transitions and interactive gestures, including
cancellation, touch arbitration and accessibility preferences. Use custom
Animated/Reanimated motion only for application-specific behavior the provided
component does not implement. Existing native-driver animations do not need a
library migration merely to satisfy this policy.

Use DESIGN.md's tokens where the component supports customization. Prefer its
system appearance and behavior over rebuilding it to reproduce a mockup's
dimensions or animation curve. Product requirements still govern behavior and
Draft safety. Resolve requirement changes through the existing
[decision process](implementation-review.md#decision-panel) and reconcile the
relevant documents. A visible design change follows the existing
[Figma design approval](implementation-review.md#design-approval) before UI code.
This policy does not authorize dropping required behavior to fit a component.

## Exceptions and review

A custom standard interaction needs a concrete gap recorded in its issue or
local task artifact: the requirement, provided APIs/packages checked and their host versions,
why they cannot meet it, the smallest retained custom part, and the condition
for deleting it. Include or link the record in the PR when delivery includes one.
Keep application-specific content separate from that exception.
Reviewers reject custom replacements that have a suitable provided equivalent.

Every migration moves all affected callers and removes its superseded controls,
bridges, presence state and motion in the same change. Add a replacement wrapper
only when the remaining requirement needs it. Verify completed and cancelled
navigation/presentations, keyboard/focus, VoiceOver, Reduced Motion and responsive
layouts through the [native validation guide](native-validation.md). Component
mocks cannot establish that a system gesture or presenter works; unavailable
native checks remain deferred before release.

## Rewrite tracking

Track the migration in [#1053](https://github.com/unwired-dev/product/issues/1053):

- [Mobile navigation, headers and search (#1055)](https://github.com/unwired-dev/product/issues/1055), after the actively claimed swipe-back fix #976.
- [Mobile sheets and popovers (#1056)](https://github.com/unwired-dev/product/issues/1056), after navigation and the existing Move picker issue #973.
- [Mobile controls and action menus (#1057)](https://github.com/unwired-dev/product/issues/1057), after the presentation migration.
- [Mac controls and presentations (#1058)](https://github.com/unwired-dev/product/issues/1058), independently within the Mac host.
- [Shared bridge/motion cleanup and qualification (#1059)](https://github.com/unwired-dev/product/issues/1059), after the client migrations.

The issues own migration scope and native blocking dependencies. Existing native
menus, file/photo pickers, sharing and window integration can already satisfy
this policy; preserve them unless a provided equivalent removes maintenance.
The comparison with T3 Code is evidence for the migration, not a requirement to
copy its custom navigator or vendored screens fork.
