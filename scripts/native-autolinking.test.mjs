import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  appendFileSync,
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

const root = fileURLToPath(new URL('..', import.meta.url));
const macFiles = ['package.json', 'react-native.config.cjs', 'macos/Podfile'];

// Copies a host's native inputs beside it, so its dependencies still resolve, and runs its check.
const verifyFixture = (host, files, change) => {
  const app = path.join(root, 'apps', host);
  const fixture = mkdtempSync(path.join(app, '.native-fixture-'));
  try {
    for (const file of files) {
      cpSync(path.join(app, file), path.join(fixture, file));
    }
    change(fixture);
    return spawnSync('node', ['scripts/verify-native.ts', fixture], {
      cwd: app,
      encoding: 'utf8',
    });
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
};

const addForeignPackage = (fixture) => {
  const packageJson = path.join(fixture, 'package.json');
  const { dependencies } = Schema.decodeSync(
    Schema.fromJsonString(
      Schema.Struct({
        dependencies: Schema.Record(Schema.String, Schema.String),
      }),
    ),
  )(readFileSync(packageJson, 'utf8'));
  writeFileSync(
    packageJson,
    JSON.stringify({
      name: 'native-fixture',
      dependencies: { ...dependencies, 'foreign-native': '1.0.0' },
    }),
  );
  const foreign = path.join(fixture, 'node_modules/foreign-native');
  mkdirSync(foreign, { recursive: true });
  writeFileSync(
    path.join(foreign, 'package.json'),
    '{"name":"foreign-native","version":"1.0.0"}',
  );
  writeFileSync(path.join(foreign, 'foreign-native.podspec'), '');
};

test('mobile autolinking rejects a foreign native dependency', () => {
  const result = verifyFixture('mobile', ['package.json'], addForeignPackage);
  assert.notEqual(result.status, 0);
  assert.match(
    result.stderr,
    /Unexpected React Native native modules[\s\S]*foreign-native/u,
  );
});

test('Mac autolinking rejects a foreign native dependency', () => {
  const result = verifyFixture('macos', macFiles, addForeignPackage);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Mac autolinking scope[\s\S]*foreign-native/u);
});

test('Mac Podfile rejects a foreign pod', () => {
  const result = verifyFixture('macos', macFiles, (fixture) => {
    appendFileSync(
      path.join(fixture, 'macos/Podfile'),
      "  pod 'ExpoModulesCore'\n",
    );
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Mac Podfile scope[\s\S]*ExpoModulesCore/u);
});
