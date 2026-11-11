import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  chmodSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';

import * as Schema from 'effect/Schema';

const offsetList = Schema.Array(Schema.Int);
const functionOffsets = Schema.Record(Schema.String, offsetList);
const composedMap = Schema.Struct({
  sources: Schema.Array(Schema.String),
  x_hermes_function_offsets: functionOffsets,
});
const decodeComposedMap = Schema.decodeSync(Schema.fromJsonString(composedMap));

const root = path.resolve(import.meta.dirname, '../../..');
const script = path.join(import.meta.dirname, 'compile-hermes-bundle.sh');
const compose = spawnSync(
  process.execPath,
  [
    '-p',
    "require('node:path').join(require('node:path').dirname(require.resolve('react-native/package.json')), 'scripts/compose-source-maps.js')",
  ],
  { cwd: path.join(root, 'apps/macos'), encoding: 'utf8' },
);

test('the Mac archive phase compiles Hermes after the Metro bundle is verified', () => {
  const source = readFileSync(
    path.join(root, 'apps/macos/scripts/create-project.rb'),
    'utf8',
  );
  assert.match(
    source,
    /pnpm verify:bundle\n {2}\/bin\/sh scripts\/compile-hermes-bundle\.sh/u,
  );
  assert.match(
    source,
    /if \[ "\$CONFIGURATION" = "Debug" \]; then exit 0; fi/u,
  );
});

test(
  'Mac release compilation replaces the Metro bundle with Hermes bytecode and a composed map',
  { skip: compose.status !== 0 },
  () => {
    mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
    const directory = mkdtempSync(path.join(root, 'scratchpad/hermes-bundle-'));
    try {
      const compiler = path.join(directory, 'hermesc');
      writeFileSync(
        compiler,
        `#!${process.execPath}
import { writeFileSync } from 'node:fs';
const args = process.argv.slice(2);
const out = args[args.indexOf('-out') + 1];
writeFileSync(out, Buffer.from('c61fbc03c103191f', 'hex'));
writeFileSync(out + '.map', JSON.stringify({
  version: 3,
  file: 'main.jsbundle',
  sources: ['main.jsbundle'],
  names: [],
  mappings: 'AAAA',
  x_hermes_function_offsets: { '0': [0, 4] },
}));
`,
        { mode: 0o755 },
      );
      chmodSync(compiler, 0o755);
      mkdirSync(path.join(directory, 'dist'));
      writeFileSync(
        path.join(directory, 'dist/main.jsbundle'),
        'var bundle = 1;\n',
      );
      writeFileSync(
        path.join(directory, 'dist/main.jsbundle.map'),
        JSON.stringify({
          version: 3,
          file: 'main.jsbundle',
          sources: ['index.js'],
          names: [],
          mappings: 'AAAA',
          sourcesContent: ['export const value = 1;\n'],
        }),
      );
      const map = path.join(directory, 'archive/main.jsbundle.map');
      const resources = path.join(
        directory,
        'UnwiredMail.app/Contents/Resources',
      );
      const result = spawnSync('/bin/sh', [script], {
        cwd: directory,
        encoding: 'utf8',
        env: {
          PATH: process.env.PATH,
          UNWIRED_MAC_BUNDLE_ROOT: directory,
          HERMES_CLI_PATH: compiler,
          SOURCEMAP_FILE: map,
          TARGET_BUILD_DIR: path.join(directory, 'UnwiredMail.app'),
          UNLOCALIZED_RESOURCES_FOLDER_PATH: 'Contents/Resources',
        },
      });
      assert.equal(result.status, 0, result.stderr);
      const bytecode = readFileSync(path.join(directory, 'dist/main.jsbundle'));
      assert.equal(bytecode.subarray(0, 8).toString('hex'), 'c61fbc03c103191f');
      const composed = decodeComposedMap(
        readFileSync(path.join(directory, 'dist/main.jsbundle.map'), 'utf8'),
      );
      assert.deepEqual(composed.x_hermes_function_offsets, { 0: [0, 4] });
      assert.ok(composed.sources.includes('index.js'));
      assert.equal(
        readFileSync(map, 'utf8'),
        readFileSync(path.join(directory, 'dist/main.jsbundle.map'), 'utf8'),
      );
      assert.deepEqual(
        readFileSync(path.join(resources, 'main.jsbundle')),
        bytecode,
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  },
);
