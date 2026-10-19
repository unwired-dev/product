# Local Expo skill corrections

Both Expo skills originate from
[`expo/skills` at `7ddc1f5`](https://github.com/expo/skills/tree/7ddc1f5796996e5c7efe2fc3fa9168eb24e8dac1/plugins/expo/skills).
`skills-lock.json` records that upstream source, not the locally patched content.
Keep the MIT licenses. On an upstream update, compare these corrections with the
new version and retain any that upstream has not incorporated.

## Expo UI

- Describe native List virtualization separately from eager React row creation;
  retain the guidance to use data-driven lists for large datasets.

- Import `Host` from the matching UI layer. Universal trees use the package root;
  SwiftUI and Compose trees use their platform subpath so platform-only props
  remain available.

- Use the exported `@expo/ui/community/datetime-picker` subpath consistently.

- Allow alternatives for a documented missing API, including accessibility and
  presentation requirements. Replacement imports are not automatically equivalent:
  [BottomSheet presents modally](https://docs.expo.dev/versions/latest/sdk/ui/drop-in-replacements/bottomsheet/),
  and [Picker omits some original props](https://docs.expo.dev/versions/latest/sdk/ui/drop-in-replacements/picker/).
- Correct platform-route guidance and show a component fallback on other
  platforms. Use platform resolution or guarded module loading; a JSX guard
  alone does not isolate static platform-only imports. Keep platform-only imports in the selected component; a rendering
  guard does not isolate a static import. [Expo Router permits platform routes when a non-platform sibling exists](https://docs.expo.dev/router/advanced/platform-specific-modules/).
- Use a JSX comment inside `RNHostView` so `Pressable` remains its first child.
- Clarify that [`useNativeState` works without worklets](https://docs.expo.dev/versions/latest/sdk/ui/swift-ui/usenativestate/);
  synchronous UI-thread worklet updates require the worklet runtime.
- Resolve wildcard declaration re-exports to their value names rather than
  reporting module names such as `Shapes`. Parse named statements across lines
  and preserve aliases;
  prevent recursion through cyclic declarations. The discovery helper is a
  compact inventory, not a TypeScript parser; confirm APIs in installed declarations.
  Its CLI regression covers both declaration formats and a script path with
  spaces, and runs in `pnpm test:tooling`.
- Keep the local CommonJS `package.json` so the upstream helper runs in this
  repository's ESM workspace.

## Expo Router

- Include Android icons in cross-platform NativeTabs examples and explicit
  dimensions on the remote zoom-source image.

- Preserve special route filenames and distinguish screen default exports from
  [special-file contracts such as `+native-intent`](https://docs.expo.dev/router/advanced/native-intent/).
- Use the named `Stack` export and import `SymbolView` in its example.
- Use `NativeTabs.Trigger.Label` and `NativeTabs.Trigger.Icon` in the route and
  search examples, with the SDK 55–57 `NativeTabs` import.
- Give sheet content an opaque background, use automatic list insets with header
  search, and keep search state with the screen that consumes it.
- State that the separate search tab requires iOS 26+ and Xcode 26+.
- Keep `Link.AppleZoom` inside a `Link` and document the
  [modal destination requirement for zoom previews](https://docs.expo.dev/router/advanced/zoom-transition/).

These are reference and tooling corrections. They do not change the maintained
apps, install `@expo/ui`, or expand the Mac host's dependency boundary.
