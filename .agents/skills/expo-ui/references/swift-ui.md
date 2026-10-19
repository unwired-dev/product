# Platform-specific iOS UI: `@expo/ui/swift-ui`

> **iOS only.** Code that imports from `@expo/ui/swift-ui` will crash on Android with "Unable to get view config" errors. Use a platform-resolved `.ios.tsx` component with a non-platform fallback, or load the component through a `require` guarded by `Platform.OS === 'ios'`. Keep platform-only imports inside that component; guarding only its JSX does not prevent module evaluation. Import `Host` from `@expo/ui/swift-ui` for platform-specific Host props; use the root `@expo/ui` Host for universal trees.

Use this layer only when the universal `@expo/ui` components don't cover what you need on iOS (see `./universal.md` first). This requires a platform-specific tree.

### File placement with Expo Router

Expo Router supports `.ios.tsx` route files inside `app/` or `src/app/` when a non-platform file with the same route name also exists. A platform-specific route without that fallback can cause a "no fallback sibling" error.

Prefer reusable platform-specific components outside the route tree. Supply a non-platform component for the other platforms, then import by extensionless path from the route:

```
src/components/ProfileEditor.tsx          ← React Native fallback on other platforms
src/components/ProfileEditor.ios.tsx   ← SwiftUI tree lives here
src/app/profile-editor.tsx             ← regular Expo Router route, imports the component
```

`src/components/ProfileEditor.tsx`:
```tsx
import { Text } from 'react-native';

export default function ProfileEditor() {
  return <Text>Profile</Text>;
}
```

`src/app/profile-editor.tsx`:
```tsx
import ProfileEditor from '../components/ProfileEditor';
export default ProfileEditor;
```

Alternatively, conditionally load the platform component from a regular route file:

```tsx
// src/app/profile-editor.tsx
import { Platform } from 'react-native';
// import SwiftUI components only when on iOS to avoid Android crash
const SwiftUIForm = Platform.OS === 'ios' ? require('../components/ProfileEditor.ios').default : null;
```

Keep platform-only imports inside the conditionally loaded component. A rendering guard does not isolate a static import; prefer the extensionless component import shown above so Metro selects the platform implementation.

## Instructions

- Expo UI's API mirrors SwiftUI's API. Use SwiftUI knowledge to decide which components or modifiers to use.
- Components are imported from `@expo/ui/swift-ui`, modifiers from `@expo/ui/swift-ui/modifiers`.
- **Before writing any code, run the list-components script** to get the exact components and modifiers available in the installed version:
  ```bash
  node <skill-root>/scripts/list-components.js <project-path>          # names only (compact)
  node <skill-root>/scripts/list-components.js <project-path> --docs   # with one-line descriptions
  ```
  (`<skill-root>` is the directory containing this `references/` folder.)
- **The installed package's TypeScript types (`.d.ts`) are the most reliable source of truth** for prop shapes and signatures — read the relevant `{Component}/index.d.ts` from the installed `@expo/ui/swift-ui` package in `node_modules`. Use the docs below as the human-readable reference.
- When about to use a component, fetch its docs to confirm the API — https://docs.expo.dev/versions/latest/sdk/ui/swift-ui/{component-name}/index.md
- When unsure about a modifier's API, refer to the docs — https://docs.expo.dev/versions/latest/sdk/ui/swift-ui/modifiers/index.md
- Every SwiftUI tree must be wrapped in `Host`.
- `RNHostView` is specifically for embedding RN components inside a SwiftUI tree. Example:

```jsx
import { Host, VStack, RNHostView } from "@expo/ui/swift-ui";
import { Pressable } from "react-native";

<Host matchContents>
  <VStack>
    <RNHostView matchContents>
      {/* Here, `Pressable` is an RN component so it is wrapped in `RNHostView`. */}
      <Pressable />
    </RNHostView>
  </VStack>
</Host>;
```

- If a required modifier or View is missing in Expo UI, it can be extended via a local Expo module. See: https://docs.expo.dev/guides/expo-ui-swift-ui/extending/index.md. Confirm with the user before extending.

## useNativeState

`useNativeState` creates observable state shared with native views and works without `react-native-worklets`. Synchronous UI-thread updates from worklets require that package. Use worklets when updates must stay synchronous, such as masking text as the user types; without the runtime, do not assume worklet timing or flicker-free formatting.

- `ObservableState.value` is readable/writable from worklets; `onChange` fires a worklet listener on state change.
- Docs — https://docs.expo.dev/versions/latest/sdk/ui/swift-ui/usenativestate/index.md
