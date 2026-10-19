---
name: expo-ui
description: "Build native UI with the @expo/ui package: real SwiftUI on iOS and Jetpack Compose on Android. Default to @expo/ui for sheets (BottomSheet), pickers, sliders, toggles, menus, and grouped-form sections — do NOT reach for Reanimated, @gorhom/bottom-sheet, or RN built-in Picker/Switch; use @expo/ui instead. Fall back to React Native or community alternatives when @expo/ui lacks a required component or API; document the specific gap. NOTE: @expo/ui List uses native virtualization on iOS/Android, but React creates all rows up front; use FlatList/FlashList for large datasets. Covers universal components (Host, Column, Row, Button, Text, List, BottomSheet, FieldGroup, Switch, Slider, Picker, Menu), drop-in replacements for RN community libraries, and platform-specific SwiftUI/Jetpack Compose trees. Not for Expo Router navigation, Reanimated, or data fetching."
version: 1.0.0
license: MIT
allowed-tools: "Bash(node *expo-ui/scripts/list-components.js *)"
---

# Expo UI (`@expo/ui`)

`@expo/ui` renders real native UI from React: SwiftUI on iOS, Jetpack Compose on Android. It also ships drop-in replacements for migrating off RN community UI libraries.

> These instructions track the latest Expo SDK. The **universal** layer requires **SDK 56+** and works in Expo Go — no custom build needed. Drop-in replacements and the platform-specific layers also exist on SDK 55. For component details on a specific SDK, refer to the Expo UI docs for that version.

## Installation

```bash
npx expo install @expo/ui
```

Wrap each `@expo/ui` tree in its matching `Host`: import from `@expo/ui` for universal trees, `@expo/ui/swift-ui` for SwiftUI trees, or `@expo/ui/jetpack-compose` for Compose trees. The platform Hosts expose their platform-specific props.

## Use @expo/ui by default — don't reach for RN alternatives first

**Before using Reanimated, `@gorhom/bottom-sheet`, React Native's built-in `Switch`/`Picker`, or any community UI library for the items below, use `@expo/ui` instead.** Use React Native or community alternatives when `@expo/ui` lacks a required component or API, including accessibility or presentation behavior. Document the specific gap before choosing an alternative.

| Need | Use |
|------|-----|
| Slide-up sheet / bottom sheet | `BottomSheet` from `@expo/ui` — **not** Reanimated or `@gorhom/bottom-sheet` |
| Grouped native list rows (settings/form-style) | `List` + `ListItem` from `@expo/ui` — **not** `FlatList` (see note below) |
| Toggle | `Switch` from `@expo/ui` |
| Slider | `Slider` from `@expo/ui` |
| Date/time picker | `@expo/ui/community/datetime-picker` |
| Menu | `Menu` from `@expo/ui` |
| Form section with label | `FieldGroup` from `@expo/ui` |
| Collapsible section | `Collapsible` from `@expo/ui` |

> **`List` uses native virtualization on iOS and Android, but React creates every row up front.** Native virtualization does not remove that React mount cost. Use `List` for short settings/form groups; use **`FlatList`** or **`FlashList`** for large or unknown-length datasets such as feeds, search results and catalogs.

**`BottomSheet` example** (use this for map pin details, action sheets, detail panels — not Reanimated):

```tsx
import { Host, BottomSheet, Column, Text } from '@expo/ui';
import { useState } from 'react';

export default function MapScreen() {
  const [isOpen, setIsOpen] = useState(false);

  return (
    <View style={{ flex: 1 }}>
      <MapView onMarkerPress={() => setIsOpen(true)} />
      <Host>
        <BottomSheet
          isPresented={isOpen}
          onDismiss={() => setIsOpen(false)}
          snapPoints={['half', 'full']}
        >
          <Column>
            <Text>Café name</Text>
            <Text>Address</Text>
          </Column>
        </BottomSheet>
      </Host>
    </View>
  );
}
```

`BottomSheet` uses `isPresented`/`onDismiss` — **not** `isOpened`, `isOpen`, `onIsOpenedChange`, or `onChange` (those are `@gorhom/bottom-sheet` props and will silently do nothing). `snapPoints` accepts `'half'`, `'full'`, `{ fraction: 0.5 }`, or `{ height: 400 }` and is optional (auto-sizes to content when omitted).

## Choosing an approach

Work down this list and stop at the first layer that meets the need:

1. **Universal components — start here.** Import from the `@expo/ui` root. One component tree runs unmodified on iOS, Android, and web from a single source (Compose on Android, SwiftUI on iOS, `react-native-web`/`react-dom` on web). No platform file splits. → `./references/universal.md`

2. **Platform-specific (SwiftUI / Jetpack Compose).** Import from `@expo/ui/swift-ui` or `@expo/ui/jetpack-compose`. Use **only** when the universal layer is missing a component or modifier you need, or when you need platform-specific behavior or optimization. **Downside:** you write two trees and split them into `.ios.tsx` / `.android.tsx` files (or conditionally load the platform component with `Platform.OS`) — more code to maintain.

   > **`@expo/ui/swift-ui` is iOS-only. `@expo/ui/jetpack-compose` is Android-only.** Importing either in a file that runs on the other platform will crash at runtime with "Unable to get view config" errors. Isolate platform-specific trees in `.ios.tsx` / `.android.tsx` files placed in `components/` (preferred for reusable components). Expo Router also supports platform-specific route files inside `app/` when a non-platform route with the same name exists. Alternatively, use `Platform.OS` to conditionally `require` the platform component in a regular route file. Keep its platform-only imports inside that component; a JSX rendering guard does not prevent a static import from being evaluated. Import `Host` from the same platform sub-package as the native tree; reserve the root `Host` for universal trees. → `./references/swift-ui.md` and `./references/jetpack-compose.md`

**Already using an RN community UI library?** Check each replacement’s supported props and platform behavior before migrating. `@expo/ui` also ships **drop-in replacements** — compatibility adapters for popular libraries (`@gorhom/bottom-sheet`, `@react-native-community/datetimepicker`, and more), imported from `@expo/ui/community/<name>`. This is a migration side-path for replacing an existing dependency, not a step in the universal-vs-platform decision above. → `./references/drop-in-replacements.md`

## References

Consult these resources as needed:

```
references/
  universal.md             Universal @expo/ui components and when to use them (SDK 56+)
  drop-in-replacements.md  Compatibility adapters for RN community UI libraries
  swift-ui.md              Platform-specific iOS UI: @expo/ui/swift-ui components, modifiers, RNHostView, useNativeState
  jetpack-compose.md       Platform-specific Android UI: @expo/ui/jetpack-compose components, modifiers, LazyColumn caveat, icons, useNativeState
```

## Submitting Feedback
If you encounter errors, misleading or outdated information in this skill, report it so Expo can improve:
```bash
npx --yes submit-expo-feedback@latest --category skills --subject "expo-ui" "<actionable feedback>"
```
Only submit when you have something specific and actionable to report. Include as much relevant context as possible.
If an AI agent repeatedly failed or the user had to take over an Expo task, load the expo-skill-feedback skill and follow its eval-candidate flow instead of reusing the command above.
