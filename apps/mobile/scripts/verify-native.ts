import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
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
    'expo-clipboard',
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
// Private Inbox's Swift packages, linked into this host by revision and resolved as recorded.
const privateInbox = fileURLToPath(
  new URL('../../../native/private-inbox/', import.meta.url),
);
const manifest = readFileSync(path.join(privateInbox, 'Package.swift'), 'utf8');
const pinned = [
  ...manifest.matchAll(
    /url: "(?<url>[^"]+)",\s*revision: "(?<revision>[0-9a-f]{40})"/gu,
  ),
].map(({ groups }) => ({ url: groups?.url, revision: groups?.revision }));
assert.deepEqual(
  pinned.map(({ url }) => url),
  [
    'https://github.com/Cocoanetics/SwiftMail.git',
    'https://github.com/apple/swift-log.git',
  ],
  'Review Swift packages before expanding the Private Inbox graph.',
);
// Each pin is resolved at its own location, so another package's revision never satisfies it.
const Pin = Schema.Struct({
  location: Schema.String,
  state: Schema.Struct({ revision: Schema.String }),
});
const ResolvedPins = Schema.fromJsonString(
  Schema.Struct({ pins: Schema.Array(Pin) }),
);
const { pins } = Schema.decodeSync(ResolvedPins)(
  readFileSync(path.join(privateInbox, 'Package.resolved'), 'utf8'),
);
const resolves = (url: string | undefined, revision: string | undefined) =>
  pins.some(
    ({ location, state }) => location === url && state.revision === revision,
  );
for (const { url, revision } of pinned) {
  assert.ok(
    resolves(url, revision),
    `Package.resolved does not record ${url} at its pinned revision.`,
  );
}
process.stdout.write(
  `Verified ${modules.length} Expo and ${Object.keys(dependencies).length} React Native autolinked modules.\n`,
);
