import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

const root = process.argv[2] ?? fileURLToPath(new URL('../', import.meta.url));
const autolinking = (command: string) =>
  execFileSync(
    'pnpm',
    [
      'exec',
      'expo-modules-autolinking',
      command,
      '--project-root',
      root,
      '--json',
    ],
    { cwd: new URL('../', import.meta.url), encoding: 'utf8' },
  );
const expoModule = Schema.Struct({ packageName: Schema.String });
const expoAutolinking = Schema.fromJsonString(
  Schema.Struct({ modules: Schema.Array(expoModule) }),
);
const reactNativeAutolinking = Schema.fromJsonString(
  Schema.Struct({ dependencies: Schema.Record(Schema.String, Schema.Unknown) }),
);
const { modules } = Schema.decodeSync(expoAutolinking)(autolinking('resolve'));
const { dependencies } = Schema.decodeSync(reactNativeAutolinking)(
  autolinking('react-native-config'),
);

// Review native modules before expanding the mobile autolinking scope.
assert.deepEqual(
  modules.map((module) => module.packageName).toSorted(),
  [
    '@expo/dom-webview',
    '@expo/log-box',
    '@expo/ui',
    'expo',
    'expo-asset',
    'expo-background-task',
    'expo-constants',
    'expo-dev-client',
    'expo-dev-launcher',
    'expo-dev-menu',
    'expo-dev-menu-interface',
    'expo-file-system',
    'expo-font',
    'expo-glass-effect',
    'expo-json-utils',
    'expo-keep-awake',
    'expo-linking',
    'expo-manifests',
    'expo-modules-core',
    'expo-modules-jsi',
    'expo-router',
    'expo-symbols',
    'expo-task-manager',
    'expo-updates-interface',
    'unimodules-app-loader',
  ],
  'Unexpected Expo native modules.',
);
assert.deepEqual(
  Object.keys(dependencies).toSorted(),
  [
    '@react-native-masked-view/masked-view',
    'expo',
    'react-native-gesture-handler',
    'react-native-reanimated',
    'react-native-safe-area-context',
    'react-native-screens',
    'react-native-webview',
    'react-native-worklets',
  ],
  'Unexpected React Native native modules.',
);
process.stdout.write(
  `Verified ${modules.length} Expo and ${Object.keys(dependencies).length} React Native autolinked modules.\n`,
);
