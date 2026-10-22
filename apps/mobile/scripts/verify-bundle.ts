import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

const dist = new URL(process.argv[2] ?? '../dist/', import.meta.url);
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
  ['Effect v4', /effect@4\.0\.0[/_]/u],
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
// Selected scenarios carry their synthetic providers. Registration JavaScript otherwise stays
// production, apart from the evaluation editor page below.
const scenario: unknown = process.env.UNWIRED_MOCK_SCENARIO;
const mockSources = sources.filter((source) =>
  source.includes('/mail-core/src/testing/'),
);
assert.equal(
  mockSources.length > 0,
  Boolean(scenario),
  'Mock providers must appear only in explicitly selected test bundles.',
);
// The synthetic trusted device's HPKE seal is the only user of these.
assert.ok(
  Boolean(scenario) ||
    !sources.some((source) =>
      /@noble[/\\](?:curves|ciphers)[/\\]/u.test(source),
    ),
  'Test-only cryptography must stay out of production bundles.',
);
// Only `registration-draft-editor` bundles carry the Tiptap evaluation page, as one packaged
// string; Tiptap and ProseMirror never join the native renderer's module graph.
assert.equal(
  sources.some((source) => source.endsWith('/draft-editor/dist/page.js')),
  scenario === 'registration-draft-editor',
  'The Tiptap evaluation page must appear only in registration-draft-editor bundles.',
);
assert.ok(
  !sources.some((source) => /@tiptap|prosemirror-/u.test(source)),
  'Tiptap must stay inside the packaged evaluation page.',
);
// Only `assistance-qualification` bundles run the synthetic assistance corpus.
assert.equal(
  sources.some((source) =>
    source.endsWith('/mail-core/src/testing/assistance-qualification.ts'),
  ),
  scenario === 'assistance-qualification',
  'The assistance qualification corpus must appear only in assistance-qualification bundles.',
);
process.stdout.write(
  `Verified ${sources.length} sources in ${fileURLToPath(dist)}: mobile renderer, Effect, shared core and native split view.\n`,
);
