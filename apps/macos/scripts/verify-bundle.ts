import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';

import * as Schema from 'effect/Schema';

const require = createRequire(import.meta.url);
const packageVersion = Schema.fromJsonString(
  Schema.Struct({ version: Schema.String }),
);
for (const [file, version] of [
  [require.resolve('react/package.json'), '19.1.4'],
  [require.resolve('react-native/package.json'), '0.81.6'],
  [require.resolve('react-native-macos/package.json'), '0.81.9'],
]) {
  assert.ok(file);
  const decoded = Schema.decodeSync(packageVersion)(
    await readFile(file, 'utf8'),
  );
  assert.equal(decoded.version, version);
}
const sourceContent = Schema.NullOr(Schema.String);
const sourceMap = Schema.fromJsonString(
  Schema.Struct({
    sources: Schema.Array(Schema.String),
    sourcesContent: Schema.Array(sourceContent),
  }),
);
const { sources, sourcesContent } = Schema.decodeSync(sourceMap)(
  await readFile(new URL('../dist/main.jsbundle.map', import.meta.url), 'utf8'),
);
for (const pattern of [
  /react@19\.1\.4[/_]/u,
  /react-native-macos@0\.81\.9[/_]/u,
  /effect@4\.0\.0[/_]/u,
  /fast-text-encoding@1\.0\.6[/_]/u,
]) {
  assert.ok(
    sources.some((source) => pattern.test(source)),
    `Missing ${pattern}`,
  );
}
for (const name of ['index', 'theme']) {
  const index = sources.findIndex((source) =>
    source.endsWith(`/mail-core/src/${name}.ts`),
  );
  assert.notEqual(index, -1, `Missing shared ${name}`);
  assert.equal(
    sourcesContent[index],
    await readFile(
      new URL(`../../../packages/mail-core/src/${name}.ts`, import.meta.url),
      'utf8',
    ),
  );
}
for (const source of sources) {
  assert.ok(
    !/[/\\]react-native@|[/\\]react@19\.2\.|react-dom[/\\]|expo[/\\]|expo-|apps[/\\]mobile|packages[/\\]convex/u.test(
      source,
    ),
    `Foreign graph: ${source}`,
  );
  if (source.includes('/node_modules/react/')) {
    assert.match(source, /react@19\.1\.4[/_]/u);
  }
  if (source.includes('/node_modules/react-native-macos/')) {
    assert.match(source, /react-native-macos@0\.81\.9[/_]/u);
  }
}
const nativeDependencies = Schema.Record(Schema.String, Schema.Unknown);
const autolinkingSchema = Schema.fromJsonString(
  Schema.Struct({
    root: Schema.String,
    reactNativePath: Schema.String,
    dependencies: nativeDependencies,
  }),
);
const autolinking = Schema.decodeSync(autolinkingSchema)(
  execFileSync('pnpm', ['exec', 'react-native', 'config'], {
    cwd: new URL('../', import.meta.url),
    encoding: 'utf8',
  }),
);
assert.equal(
  autolinking.reactNativePath,
  path.dirname(require.resolve('react-native-macos/package.json')),
);
assert.equal(
  autolinking.root,
  path.dirname(require.resolve('../package.json')),
);
assert.deepEqual(
  Object.keys(autolinking.dependencies),
  [],
  'Review native modules before expanding the Mac autolinking scope.',
);
// Registration scenarios substitute a native provider only; their JavaScript stays production.
const scenario: unknown = process.env.UNWIRED_MOCK_SCENARIO;
const nativeOnly =
  typeof scenario === 'string' && scenario.startsWith('registration-');
const mockSources = sources.filter((source) =>
  source.includes('/mail-core/src/testing/'),
);
assert.equal(
  mockSources.length > 0,
  Boolean(scenario) && !nativeOnly,
  'Mock providers must appear only in explicitly selected test bundles.',
);
process.stdout.write(
  `Verified ${sources.length} Mac sources, shared fixture and host-only autolinking.\n`,
);
