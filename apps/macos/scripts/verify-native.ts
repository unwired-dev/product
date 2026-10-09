import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
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
// The isolated WebKit message reader is the only autolinked module.
assert.deepEqual(
  Object.keys(autolinking.dependencies),
  ['react-native-webview'],
  'Review native modules before expanding the Mac autolinking scope.',
);
const podfile = await readFile(path.join(root, 'macos/Podfile'), 'utf8');
// Unrecognized pod arguments stay undefined so the allowlist fails closed.
assert.deepEqual(
  Array.from(
    podfile.matchAll(
      /(?:^|;)\s*pod\b\s*(?:\(\s*)?(?:['"](?<pod>[^'"]+)['"])?/gmu,
    ),
    (match) => match.groups?.pod,
  ),
  ['GoogleSignIn'],
  'Review pods before expanding the Mac Podfile scope.',
);
process.stdout.write('Verified host-only Mac autolinking and Podfile pods.\n');
