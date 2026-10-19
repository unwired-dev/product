# Drop-in replacements for RN community libraries

`@expo/ui` ships compatibility adapters for popular React Native community libraries, powered by native components. Before changing imports, check the installed SDK’s types, compatibility notes, accessibility props, and presentation behavior against the caller’s requirements. These adapters are not always behavior-equivalent: the bottom-sheet replacement uses modal presentation and cannot preserve a persistent inline peek; the Picker replacement does not support every original prop, including `accessibilityLabel`. Keep an alternative when a documented API gap prevents preserving required behavior.

## Available replacements

Every drop-in lives under `@expo/ui/community/<kebab-case-name>`. Note which are default vs named imports.

| Replaces | Import |
|----------|--------|
| `@gorhom/bottom-sheet` | `import BottomSheet, { BottomSheetView } from '@expo/ui/community/bottom-sheet'` |
| `@react-native-community/datetimepicker` | `import DateTimePicker from '@expo/ui/community/datetime-picker'` |
| `@react-native-masked-view/masked-view` | `import { MaskedView } from '@expo/ui/community/masked-view'` |
| `@react-native-menu/menu` | `import { MenuView } from '@expo/ui/community/menu'` |
| `react-native-pager-view` | `import PagerView from '@expo/ui/community/pager-view'` |
| `@react-native-picker/picker` | `import { Picker } from '@expo/ui/community/picker'` |
| `@react-native-segmented-control/segmented-control` | `import SegmentedControl from '@expo/ui/community/segmented-control'` |
| `@react-native-community/slider` | `import Slider from '@expo/ui/community/slider'` |

## Confirming the API

Each component has a dedicated docs page with setup and usage:

- Overview — https://docs.expo.dev/versions/latest/sdk/ui/drop-in-replacements/index.md
- Per component — https://docs.expo.dev/versions/latest/sdk/ui/drop-in-replacements/{component}/index.md (slug is the component name lowercased, no hyphens, e.g. `bottomsheet`, `datetimepicker`, `segmentedcontrol`)

The installed package's TypeScript types (`.d.ts`) are the most reliable source of truth for the exact props on your SDK version (@expo/ui is versioned with the SDK and its API can change between versions). Use the doc page to find platform support and any props that differ from the library being replaced.
