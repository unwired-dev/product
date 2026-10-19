# Platform-specific Android UI: `@expo/ui/jetpack-compose`

> **Android only.** Code that imports from `@expo/ui/jetpack-compose` will crash on iOS with "Unable to get view config" errors. Always place this code in an `.android.tsx` component file or guard it with `Platform.OS === 'android'`. Import `Host` from `@expo/ui/jetpack-compose` for platform-specific Host props; use the root `@expo/ui` Host for universal trees.

Use this layer only when the universal `@expo/ui` components don't cover what you need on Android (see `./universal.md` first). This requires a platform-specific tree.

### File placement with Expo Router

Expo Router supports `.android.tsx` route files inside `app/` or `src/app/` when a non-platform file with the same route name also exists. A platform-specific route without that fallback can cause a "no fallback sibling" error.

Prefer reusable platform-specific components outside the route tree. Supply a non-platform component for the other platforms, then import by extensionless path from the route:

```
src/components/ProductList.tsx          ← React Native fallback on other platforms
src/components/ProductList.android.tsx   ← Compose tree lives here
src/app/product-list.tsx                 ← regular Expo Router route, imports the component
```

`src/components/ProductList.tsx`:
```tsx
import { Text } from 'react-native';

export default function ProductList() {
  return <Text>Products</Text>;
}
```

`src/app/product-list.tsx`:
```tsx
import ProductList from '../components/ProductList';
export default ProductList;
```

Alternatively, keep everything in one regular route file and branch on `Platform.OS`:

```tsx
// src/app/product-list.tsx
import { Platform } from 'react-native';
const ComposeList = Platform.OS === 'android' ? require('../components/ProductList.android').default : null;
```

## Instructions

- Expo UI's API mirrors Jetpack Compose's API. Use Jetpack Compose and Material Design 3 knowledge to decide which components or modifiers to use. If you need deeper Jetpack Compose or Material 3 guidance (e.g. which component to pick, layout patterns, theming), spawn a subagent to research [Jetpack Compose](https://developer.android.com/develop/ui/compose/components) and [Material Design 3](https://m3.material.io/) best practices.
- Components are imported from `@expo/ui/jetpack-compose`, modifiers from `@expo/ui/jetpack-compose/modifiers`.
- **Before writing any code, run the list-components script** to get the exact components and modifiers available in the installed version:
  ```bash
  node <skill-root>/scripts/list-components.js <project-path>          # names only (compact)
  node <skill-root>/scripts/list-components.js <project-path> --docs   # with one-line descriptions
  ```
  (`<skill-root>` is the directory containing this `references/` folder.)
- **Always read the `.d.ts` type files** to confirm prop shapes and signatures — read the relevant `{ComponentName}/index.d.ts` from the installed `@expo/ui/jetpack-compose` package in `node_modules`. This is the most reliable source of truth.
- When about to use a component, fetch its docs to confirm the API — https://docs.expo.dev/versions/latest/sdk/ui/jetpack-compose/{component-name}/index.md
- When unsure about a modifier's API, refer to the docs — https://docs.expo.dev/versions/latest/sdk/ui/jetpack-compose/modifiers/index.md
- Every Jetpack Compose tree must be wrapped in `Host`. Use `<Host matchContents>` for intrinsic sizing, or `<Host style={{ flex: 1 }}>` when you need explicit size (e.g. as a parent of `LazyColumn`). Example:

```jsx
import { Host, Column, Button, Text } from "@expo/ui/jetpack-compose";
import { fillMaxWidth, paddingAll } from "@expo/ui/jetpack-compose/modifiers";

<Host matchContents>
  <Column verticalArrangement={{ spacedBy: 8 }} modifiers={[fillMaxWidth(), paddingAll(16)]}>
    <Text style={{ typography: "titleLarge" }}>Hello</Text>
    <Button onPress={() => alert("Pressed!")}>Press me</Button>
  </Column>
</Host>;
```

- `RNHostView` embeds React Native components inside a Jetpack Compose tree (the same concept as in `@expo/ui/swift-ui`) — wrap any RN child in `<RNHostView>`.
- If a required composable or modifier is missing in Expo UI, it can be extended via a local Expo module. See: https://docs.expo.dev/guides/expo-ui-jetpack-compose/extending/index.md. Confirm with the user before extending.

## Key Components

- **LazyColumn** — Use instead of react-native `ScrollView`/`FlatList` for scrollable lists. Wrap in `<Host style={{ flex: 1 }}>`. Not suitable for large lists — each item is a JSX node processed on the JS thread, which causes noticeable slowdowns at scale.
- **Icon** — Use `<Icon source={require('./icon.xml')} size={24} />` with Android XML vector drawables. To get icons: go to [Material Symbols](https://fonts.google.com/icons), select an icon, choose the Android platform, and download the XML vector drawable. Save these as `.xml` files in your project's `assets/` directory (e.g. `assets/icons/wifi.xml`). Metro bundles `.xml` assets automatically — no metro config changes needed.

## useNativeState

`useNativeState` creates observable state shared with native views and works without `react-native-worklets`. Synchronous UI-thread updates from worklets require that package. Use worklets when updates must stay synchronous, such as masking text as the user types; without the runtime, do not assume worklet timing or flicker-free formatting.

- `ObservableState.value` is readable/writable from worklets; `onChange` fires a worklet listener on state change.
- Docs — https://docs.expo.dev/versions/latest/sdk/ui/jetpack-compose/usenativestate/index.md
