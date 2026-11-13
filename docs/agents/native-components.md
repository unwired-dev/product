# Native component selection

Use native, React Native and Expo-provided components for standard platform
interactions. This applies to new UI and changes to existing UI in the maintained
mobile and Mac clients. An existing custom implementation is migration work,
not a precedent to copy.

## Choose the provided implementation

Before implementing a standard interaction, record the component choice, with
the API and installed versions checked, in the existing issue or task plan. State
which behavior the framework owns and which mail requirements remain
application-owned, such as Draft save guards or a nonmodal composer. Record any
remaining gap under [exceptions and review](#exceptions-and-review). This is part
of planning, not a separate approval or review stage.

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
is not the default shortcut to a missing control. Existing native menus,
file/photo pickers, sharing and window integration can already satisfy this
policy; preserve them unless a provided equivalent removes maintenance.

Confirm skill examples against the installed package's exports and declarations.
When compatibility or behavior is uncertain, use the smallest task-owned probe
of the required interaction before building surrounding UI. A custom component
already in the app, a matching screenshot or an example from another host does
not establish a missing framework API.

## Native behavior and design

Let the native presenter own its transitions and interactive gestures, including
cancellation, touch arbitration and accessibility preferences. Use custom
Animated/Reanimated motion only for application-specific behavior the provided
component does not implement. Existing native-driver animations do not need a
library migration merely to satisfy this policy.

Use DESIGN.md's tokens where the component supports customization. Prefer its
system appearance and behavior over rebuilding it to reproduce a mockup's
dimensions or animation curve. The [frames rule](../../AGENTS.md#design) still
decides what the component does, and Draft safety holds whatever it offers. This
policy does not authorize dropping required behavior to fit a component.

Layouts hold at window and screen sizes other than the frame's, keep 44pt touch
targets on iPhone and iPad, and keep controls and final content rows clear of
floating chrome such as the search bar, toolbar groups and the composer.

## Exceptions and review

A custom standard interaction needs a concrete gap recorded in its issue or
local task artifact: the requirement, provided APIs/packages checked and their host versions,
the provided object's documented configuration properties, the installed declarations
searched (file and symbols), why they cannot meet it, the smallest retained custom part, and the condition
for deleting it. Include or link the record in the PR when delivery includes one.
Keep application-specific content separate from that exception.
Reviewers reject custom replacements that have a suitable provided equivalent.
Check the recorded component choice before reviewing its styling. A known
custom-control follow-up does not satisfy the exception rule; validate an API
gap or replace the standard interaction within the agreed scope.

Every migration moves all affected callers and removes its superseded controls,
bridges, presence state and motion in the same change. Add a replacement wrapper
only when the remaining requirement needs it. Before expanding the change,
exercise the smallest affected native journey (open, interact, cancel and
reopen), then verify completed and cancelled navigation/presentations,
keyboard/focus, VoiceOver, Reduced Motion and responsive layouts under the
[native validation guide](native-validation.md) and the
[testing policy](testing.md#proportionate-verification); mocks do not validate a
system gesture, presenter or presentation workaround.

The [migration epic #1053](https://github.com/unwired-dev/product/issues/1053)
tracks remaining migrations, and the mobile [navigation](../expo-client.md#navigation)
docs record its navigation exceptions. Each exception stays until its deletion
condition holds.

### Recorded exceptions

**iOS SF Symbols.** `expo-symbols` `SymbolView` has no point-size prop (checked
through 58.0.4), so `SFSymbol` in `apps/mobile/src/design.tsx` keeps the iOS
`UnwiredSymbolView` and `UnwiredSymbolManager` in `native/design/UnwiredDesign.m`;
delete them and use `SymbolView` once a supported release renders at a given
point size. The Mac `UnwiredSymbolView` is not part of this exception.

## Skills

For React, React Native or Expo implementation and review, load
`vercel-react-native-skills` and `vercel-composition-patterns` before editing;
apply composition patterns only to the components the task needs. Then select by
task:

- Expo controls and presenters: the project-local [expo-ui skill](../../.agents/skills/expo-ui/SKILL.md).
- Expo routes, native stacks, headers, search and sheets: the project-local [expo-router skill](../../.agents/skills/expo-router/SKILL.md).
- Expo SDK upgrades: the project-local [expo-upgrade skill](../../.agents/skills/expo-upgrade/SKILL.md).
- Animation and motion: the [animation skills](#animation-skills) below.
- Measured performance problems: Callstack's `react-native-best-practices`.

Apply guidance to the host's installed versions. Repository component selection,
design, Effect and dependency-boundary rules take precedence over generic skill
examples. Expo guidance applies to the mobile host; it does not authorize adding
Expo to the Mac bundle. Load relevant references, rather than treating every
skill as a reason to add dependencies, wrappers or a component framework.
When updating `expo-ui` or `expo-router`, reapply the
[local corrections](expo-skill-patches.md).

### Animation skills

Any task that adds, changes or reviews animation, motion, transitions, gestures,
press feedback or haptics must load the matching animation skill before planning
or editing, in addition to the design skills in the root guide:

- React Native and Expo motion, including Reanimated, Gesture Handler, screen
  and sheet transitions, press feedback and expo-haptics: the project-local
  [expo-animation skill](../../.agents/skills/expo-animation/SKILL.md), and
  `animate-expo` when the session catalogue has it.
- Motion principles and review: `apple-design`.

The native presenter still owns its own transitions under
[native behavior and design](#native-behavior-and-design). Repository design
tokens and Reduced Motion requirements take precedence over skill examples.
