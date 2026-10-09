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

test('Mac Podfile accepts literal pod names and ignores comments and strings', () => {
  for (const declaration of [
    "pod('GoogleSignIn', '10.0.0')",
    "pod(\n    'GoogleSignIn', '10.0.0'\n  )",
    "pod %q(GoogleSignIn), '10.0.0'",
  ]) {
    const result = verifyFixture('macos', macFiles, (fixture) => {
      const podfile = path.join(fixture, 'macos/Podfile');
      const content = readFileSync(podfile, 'utf8').replace(
        "pod 'GoogleSignIn', '10.0.0'",
        declaration,
      );
      writeFileSync(
        podfile,
        `${content}\n# Comment; pod "ExpoModulesCore"\nnote = "pod('ExpoModulesCore')"\n`,
      );
    });
    assert.equal(result.status, 0, result.stderr);
  }
});

test('Mac Podfile rejects a foreign pod', () => {
  for (const declaration of [
    "  pod 'ExpoModulesCore'\n",
    "  pod('ExpoModulesCore')\n",
    '  pod (\n    "ExpoModulesCore"\n  )\n',
    "  platform :macos, '27.0'; pod 'ExpoModulesCore'\n",
    '  pod %q(ExpoModulesCore)\n',
    "  if true then pod 'ExpoModulesCore' end\n",
    "  self.pod('ExpoModulesCore')\n",
  ]) {
    const result = verifyFixture('macos', macFiles, (fixture) => {
      appendFileSync(path.join(fixture, 'macos/Podfile'), declaration);
    });
    assert.notEqual(result.status, 0, declaration);
    assert.match(result.stderr, /Mac Podfile scope/u);
  }
});

test('Mac Podfile rejects a computed pod name with an allowed prefix', () => {
  for (const declaration of [
    "  pod 'GoogleSignIn' + 'Foreign', '10.0.0'\n",
    "  pod('GoogleSignIn' + 'Foreign', '10.0.0')\n",
    "  pod 'GoogleSignIn'\n    .concat('Foreign')\n",
    "  pod(\n    'GoogleSignIn'\n    .concat('Foreign')\n  )\n",
    '  pod "GoogleSignIn#{\'Foreign\'}"\n',
  ]) {
    const result = verifyFixture('macos', macFiles, (fixture) => {
      const podfile = path.join(fixture, 'macos/Podfile');
      writeFileSync(
        podfile,
        readFileSync(podfile, 'utf8').replace(
          "  pod 'GoogleSignIn', '10.0.0'\n",
          declaration,
        ),
      );
    });
    assert.notEqual(result.status, 0, declaration);
    assert.match(result.stderr, /Mac Podfile scope/u);
  }
});
