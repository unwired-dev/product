import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

const dist = new URL('../dist/', import.meta.url);
const files = await readdir(dist, { recursive: true });
const maps = files.filter((file) => file.endsWith('.map'));
assert.ok(
  maps.length > 0,
  'Export the production iOS bundle with source maps first.',
);

const sourceContent = Schema.NullOr(Schema.String);
const sourceMap = Schema.fromJsonString(
  Schema.Struct({
    sources: Schema.Array(Schema.String),
    sourcesContent: Schema.Array(sourceContent),
  }),
);
const sources: string[] = [];
for (const map of maps) {
  const decoded = Schema.decodeSync(sourceMap)(
    await readFile(new URL(map, dist), 'utf8'),
  );
  for (const name of ['index', 'theme']) {
    const index = decoded.sources.findIndex((source) =>
      source.endsWith(`/mail-core/src/${name}.ts`),
    );
    if (index !== -1) {
      assert.equal(
        decoded.sourcesContent[index],
        await readFile(
          new URL(
            `../../../packages/mail-core/src/${name}.ts`,
            import.meta.url,
          ),
          'utf8',
        ),
        `Stale shared ${name} source: re-export the production bundle.`,
      );
    }
  }
  sources.push(...decoded.sources);
}

const inventory = [
  ['React 19.2.3', /react@19\.2\.3[/_]/u],
  ['React Native 0.86.3', /react-native@0\.86\.3[/_]/u],
  ['Effect v4', /effect@4\.0\.0-rc\.118[/_]/u],
  ['Shared mail core', /mail-core.*[/\\]src[/\\]index\.ts$/u],
  ['Native split view', /expo-router[/\\]build[/\\]split-view[/\\]/u],
] satisfies ReadonlyArray<readonly [string, RegExp]>;

for (const [name, pattern] of inventory) {
  assert.ok(
    sources.some((source) => pattern.test(source)),
    `Missing ${name} in production bundle.`,
  );
}
for (const source of sources) {
  if (source.includes('/node_modules/react/')) {
    assert.match(source, /react@19\.2\.3[/_]/u, 'Unexpected React version.');
  }
  if (source.includes('/node_modules/react-native/')) {
    assert.match(
      source,
      /react-native@0\.86\.3[/_]/u,
      'Unexpected native renderer.',
    );
  }
  assert.ok(
    !/react-native-macos|react-native@0\.81\.|react@19\.1\./u.test(source),
    `Foreign native graph: ${source}`,
  );
  assert.ok(
    !/react-dom[/\\]|packages[/\\]convex[/\\]/u.test(source),
    `Unexpected platform dependency: ${source}`,
  );
}
const mockSources = sources.filter((source) =>
  source.includes('/mail-core/src/testing/'),
);
assert.equal(
  mockSources.length > 0,
  Boolean(process.env.UNWIRED_MOCK_SCENARIO),
  'Mock providers must appear only in explicitly selected test bundles.',
);
process.stdout.write(
  `Verified ${sources.length} sources in ${fileURLToPath(dist)}: mobile renderer, Effect, shared core and native split view.\n`,
);
