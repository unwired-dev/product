import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

const require = createRequire(import.meta.url);
const root = path.resolve(
  process.argv[2] ?? fileURLToPath(new URL('../', import.meta.url)),
);
const autolinkingSchema = Schema.fromJsonString(
  Schema.Struct({
    root: Schema.String,
    reactNativePath: Schema.String,
    dependencies: Schema.Record(Schema.String, Schema.Unknown),
  }),
);
const reactNative = fileURLToPath(
  new URL('../node_modules/.bin/react-native', import.meta.url),
);
const autolinking = Schema.decodeSync(autolinkingSchema)(
  execFileSync(reactNative, ['config'], { cwd: root, encoding: 'utf8' }),
);
assert.equal(
  autolinking.reactNativePath,
  path.dirname(require.resolve('react-native-macos/package.json')),
);
assert.equal(autolinking.root, root);
// Clipboard and the isolated WebKit message reader are the reviewed native modules.
assert.deepEqual(
  Object.keys(autolinking.dependencies),
  ['@react-native-clipboard/clipboard', 'react-native-webview'],
  'Review native modules before expanding the Mac autolinking scope.',
);
const podSchema = Schema.fromJsonString(
  Schema.Array(Schema.NullOr(Schema.String)),
);
const podOutput = execFileSync(
  'ruby',
  [
    fileURLToPath(new URL('verify-pods.rb', import.meta.url)),
    path.join(root, 'macos/Podfile'),
  ],
  { encoding: 'utf8' },
);
assert.deepEqual(
  Schema.decodeSync(podSchema)(podOutput),
  ['GoogleSignIn'],
  'Review pods before expanding the Mac Podfile scope.',
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
    'https://github.com/getsentry/sentry-cocoa.git',
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
process.stdout.write('Verified host-only Mac autolinking and Podfile pods.\n');
