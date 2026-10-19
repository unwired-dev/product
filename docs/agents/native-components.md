# Native component selection

Use native, React Native and Expo-provided components for standard platform
interactions. This applies to new UI and changes to existing UI in the maintained
mobile and Mac clients. An existing custom implementation is migration work,
not a precedent to copy.

## Choose the provided implementation

Before implementing a standard interaction, record the component choice in the
existing issue or task plan. Name the supported API, the installed host/package
versions and the declaration or official reference checked. State which behavior
the framework owns and which mail requirements remain application-owned, such as
Draft save guards or a nonmodal composer. Record any remaining gap under
[exceptions and review](#exceptions-and-review). This is part of planning, not a
separate approval or review stage.

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
Check the recorded component choice before reviewing its styling. A known
custom-control follow-up does not satisfy the exception rule; validate an API
gap or replace the standard interaction within the agreed scope.

Every migration moves all affected callers and removes its superseded controls,
bridges, presence state and motion in the same change. Add a replacement wrapper
only when the remaining requirement needs it. Verify completed and cancelled
navigation/presentations, keyboard/focus, VoiceOver, Reduced Motion and responsive
layouts through the [native validation guide](native-validation.md). Component
mocks cannot establish that a system gesture or presenter works; unavailable
native checks remain deferred before release.

Exercise the smallest affected native journey before expanding the change:
open, interact, cancel and reopen, including keyboard/focus where relevant.
Use the existing native runner and its resource-ownership rules. When the target
is unavailable, record that limitation and use the strongest deterministic
evidence under the [testing policy](testing.md#proportionate-verification).
Keep the native interaction check deferred; passing mocks do not validate a
presentation workaround.

## Skills

Use each skill that applies to the task, resolving global skills through the
session catalogue and missing skills through the existing discovery workflow:

- React Native rendering, lists and native integration: `vercel-react-native-skills`.
- Expo controls and presenters: the project-local [expo-ui skill](../../.agents/skills/expo-ui/SKILL.md).
- Expo routes, native stacks, headers, search and sheets: the project-local [expo-router skill](../../.agents/skills/expo-router/SKILL.md).
- Component APIs and refactors: `vercel-composition-patterns`, scoped to simplifying the components the task needs.
- TypeScript models and contracts: `typescript-best-practices`.
- Behavior and regression coverage: `functionality-testing`, with real native evidence where the behavior depends on the host.
- Simplicity and minimal changes: `ponytail`, subject to this policy's provided-component preference.
- Measured performance problems: Callstack's `react-native-best-practices`; resolve it through skill discovery when needed, rather than installing it for every task.

Apply guidance to the host's installed versions. Repository component selection,
design, Effect and dependency-boundary rules take precedence over generic skill
examples. Expo guidance applies to the mobile host; it does not authorize adding
Expo to the Mac bundle. Load relevant references, rather than treating every
skill as a reason to add dependencies, wrappers or a component framework.

The two Expo bundles are vendored from the revision in `skills-lock.json`.
Preserve the pin and reapply the documented [local corrections](expo-skill-patches.md)
when updating them. The local `expo-ui` package manifest keeps its CommonJS
discovery helper compatible with this ESM workspace.

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
