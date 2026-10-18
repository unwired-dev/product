import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { test } from 'node:test';

import * as Schema from 'effect/Schema';

const root = path.resolve(import.meta.dirname, '..');
const script = path.join(import.meta.dirname, 'reporting-artifacts.mjs');

const parseManifest = Schema.decodeSync(
  Schema.fromJsonString(
    Schema.Struct({
      chunkId: Schema.String,
      nativeIds: Schema.Array(Schema.String),
      cli: Schema.Struct({ version: Schema.String }),
      qualification: Schema.String,
      uploadCommands: Schema.Array(Schema.Array(Schema.String)),
    }),
  ),
);
const parseMap = Schema.decodeSync(
  Schema.fromJsonString(Schema.Struct({ chunk_id: Schema.String })),
);

function invocation(directory) {
  return [
    '--platform',
    'ios',
    '--version',
    '1.0.0',
    '--build',
    '202610181230',
    '--bundle',
    path.join(directory, 'main.hbc'),
    '--map',
    path.join(directory, 'main.hbc.map'),
    '--binary',
    path.join(directory, 'App'),
    '--dsym',
    path.join(directory, 'App.app.dSYM'),
    '--output',
    path.join(directory, 'prepared'),
  ];
}

function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result;
}

test('artifact preparation refuses plain Metro maps, non-Hermes bundles and unsafe release coordinates', () => {
  const directory = mkdtempSync(path.join(root, 'scratchpad/reporting-test-'));
  try {
    const bytecode = Buffer.alloc(32);
    Buffer.from('c61fbc03c103191f', 'hex').copy(bytecode);
    writeFileSync(path.join(directory, 'main.hbc'), bytecode);
    writeFileSync(
      path.join(directory, 'main.hbc.map'),
      JSON.stringify({ version: 3, sources: ['index.js'], mappings: 'AAAA' }),
    );
    const mapFailure = spawnSync(
      process.execPath,
      [script, ...invocation(directory)],
      { encoding: 'utf8' },
    );
    assert.equal(mapFailure.status, 1);
    assert.match(mapFailure.stderr, /composed Hermes map/u);
    writeFileSync(path.join(directory, 'main.hbc'), 'plain JavaScript');
    const bytecodeFailure = spawnSync(
      process.execPath,
      [script, ...invocation(directory)],
      { encoding: 'utf8' },
    );
    assert.match(bytecodeFailure.stderr, /not Hermes bytecode/u);
    const coordinateFailure = spawnSync(
      process.execPath,
      [script, ...invocation(directory), '--version', 'private@example.com'],
      { encoding: 'utf8' },
    );
    assert.equal(coordinateFailure.status, 1);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test(
  'prepares real Hermes and matching Mach-O dSYM artifacts without upload; refuses a mismatched executable',
  { skip: process.platform !== 'darwin' },
  () => {
    const directory = mkdtempSync(
      path.join(root, 'scratchpad/reporting-test-'),
    );
    try {
      const reactNative = realpathSync(
        path.join(root, 'apps/mobile/node_modules/react-native/package.json'),
      );
      const require = createRequire(reactNative);
      const compiler = path.join(
        path.dirname(require.resolve('hermes-compiler/package.json')),
        'hermesc/osx-bin/hermesc',
      );
      writeFileSync(
        path.join(directory, 'main.js'),
        "function syntheticCrash(){throw new Error('Synthetic native crash')}syntheticCrash();",
      );
      run(compiler, [
        '-emit-binary',
        '-output-source-map',
        '-out',
        path.join(directory, 'main.hbc'),
        path.join(directory, 'main.js'),
      ]);
      writeFileSync(
        path.join(directory, 'main.c'),
        'int main(void){return 0;}\n',
      );
      run('/usr/bin/xcrun', [
        'clang',
        '-g',
        '-o',
        path.join(directory, 'App'),
        path.join(directory, 'main.c'),
      ]);
      run('/usr/bin/xcrun', [
        'dsymutil',
        path.join(directory, 'App'),
        '-o',
        path.join(directory, 'App.app.dSYM'),
      ]);
      writeFileSync(
        path.join(directory, 'Info.plist'),
        '<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.0.0</string><key>CFBundleVersion</key><string>202610181230</string></dict></plist>',
      );
      const originalBytecode = readFileSync(path.join(directory, 'main.hbc'));
      run(process.execPath, [script, ...invocation(directory)]);
      // JSON is the script's public artifact format.
      const manifest = parseManifest(
        readFileSync(path.join(directory, 'prepared/manifest.json'), 'utf8'),
      );
      const map = parseMap(
        readFileSync(
          path.join(directory, 'prepared/hermes/index.bundle.map'),
          'utf8',
        ),
      );
      assert.equal(map.chunk_id, 'app:///ios/1.0.0/202610181230/index.bundle');
      assert.equal(manifest.chunkId, map.chunk_id);
      assert.equal(manifest.nativeIds.length, 1);
      assert.equal(manifest.cli.version, '0.18.10');
      assert.deepEqual(
        readFileSync(path.join(directory, 'main.hbc')),
        originalBytecode,
      );
      assert.match(manifest.qualification, /pending/u);
      assert.equal(manifest.uploadCommands[0][2], 'https://eu.posthog.com');
      rmSync(path.join(directory, 'prepared'), { recursive: true });
      const wrongBuild = spawnSync(
        process.execPath,
        [script, ...invocation(directory), '--build', '42'],
        { encoding: 'utf8' },
      );
      assert.equal(wrongBuild.status, 1);
      assert.match(wrongBuild.stderr, /do not match/u);
      writeFileSync(
        path.join(directory, 'different.c'),
        'int main(void){return 1;}\n',
      );
      run('/usr/bin/xcrun', [
        'clang',
        '-g',
        '-o',
        path.join(directory, 'App'),
        path.join(directory, 'different.c'),
      ]);
      const mismatch = spawnSync(
        process.execPath,
        [script, ...invocation(directory)],
        { encoding: 'utf8' },
      );
      assert.equal(mismatch.status, 1);
      assert.match(mismatch.stderr, /does not match/u);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  },
);
