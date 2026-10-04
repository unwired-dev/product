import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  cpSync,
  existsSync,
  readdirSync,
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
const parseJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);
const scenarios = [
  ['success', 0, 2],
  ['delete-failure', 1, 2],
  ['terminated', 143, 1],
  ['multiple-tests', 0, 2],
  ['no-results', 1, 1],
  ['assertion-with-connection-log', 1, 1],
  ['assertion-with-infrastructure-error', 1, 1],
  ['socket', 0, 3],
  ['disconnect', 0, 3],
  ['zero', 0, 3],
  ['persistent', 1, 2],
  ['assertion', 1, 1],
  // CI runs one device per job; a selection must run exactly that device.
  [
    'selected-device',
    0,
    1,
    ['com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB'],
  ],
];

for (const [
  scenario,
  expectedExit,
  expectedDevices,
  deviceTypes = [],
] of scenarios) {
  test(`native runner: ${scenario}`, () => {
    mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
    const directory = mkdtempSync(path.join(root, 'scratchpad/native-runner-'));
    try {
      const scripts = path.join(directory, 'apps/mobile/scripts');
      const nativeTests = path.join(directory, 'apps/mobile/native-tests');
      const bin = path.join(directory, 'bin');
      for (const directoryPath of [
        scripts,
        nativeTests,
        bin,
        path.join(directory, 'Preview.app'),
        path.join(directory, 'scripts'),
      ]) {
        mkdirSync(directoryPath, { recursive: true });
      }
      cpSync(
        path.join(root, 'apps/mobile/scripts/test-native.zsh'),
        path.join(scripts, 'test-native.zsh'),
      );
      writeFileSync(path.join(nativeTests, 'InboxTests.swift'), '');
      cpSync(
        path.join(root, 'scripts/prepare-mock-app.py'),
        path.join(directory, 'scripts/prepare-mock-app.py'),
      );
      cpSync(
        path.join(root, 'scripts/mock-mail-scenarios.json'),
        path.join(directory, 'scripts/mock-mail-scenarios.json'),
      );
      writeFileSync(
        path.join(directory, 'Preview.app/Info.plist'),
        `<?xml version="1.0"?><plist version="1.0"><dict><key>UnwiredMockScenario</key><string>open-read-relaunch</string></dict></plist>`,
      );
      const stub = `#!${process.execPath}
import fs from 'node:fs';
import path from 'node:path';
const base = ${JSON.stringify(directory)};
const scenario = ${JSON.stringify(scenario)};
const command = path.basename(process.argv[1]);
const args = process.argv.slice(2);
const next = (name) => {
  const file = path.join(base, name);
  const count = fs.existsSync(file) ? Number(fs.readFileSync(file, 'utf8')) + 1 : 1;
  fs.writeFileSync(file, String(count));
  return count;
};
if (command === 'xcrun' && args[1] === 'create') { fs.appendFileSync(path.join(base, 'created'), args[3] + '\\n'); console.log('owned-' + next('devices')); }
if (command === 'xcrun' && args[1] === 'delete') { fs.appendFileSync(path.join(base, 'deleted'), args[2] + '\\n'); if (scenario === 'delete-failure') process.exit(1); }
if (command === 'xcodebuild' && args[0] === 'test-without-building') {
  const attempt = next('attempts');
  if (scenario === 'terminated') { process.kill(process.ppid, 'SIGTERM'); process.exit(143); }
  if (scenario === 'no-results') process.exit(0);
  if (scenario === 'multiple-tests') { console.log('Executed 2 tests, with 0 failures'); process.exit(0); }
  if (scenario === 'assertion-with-connection-log') { console.log('testmanagerd connection established'); console.log('XCTAssertTrue failed'); process.exit(65); }
  if (scenario === 'assertion-with-infrastructure-error') { console.log('CoreSimulator service disconnected'); console.log('XCTAssertTrue failed'); process.exit(65); }
  if (scenario === 'assertion') { console.log('XCTAssertEqual failed'); process.exit(65); }
  if (scenario === 'persistent' || attempt === 1) {
    if (scenario === 'socket' || scenario === 'persistent') { console.log('testmanagerd socket missing'); process.exit(65); }
    if (scenario === 'disconnect') { console.log('CoreSimulator service disconnected'); process.exit(65); }
    if (scenario === 'zero') { console.log('Executed 0 tests, with 0 failures'); process.exit(0); }
  }
  console.log('Executed 1 test, with 0 failures');
}
`;
      for (const command of ['xcrun', 'xcodebuild', 'ruby', 'codesign']) {
        writeFileSync(path.join(bin, command), stub, { mode: 0o755 });
      }
      const result = spawnSync(
        'zsh',
        [
          path.join(scripts, 'test-native.zsh'),
          path.join(directory, 'Preview.app'),
          ...deviceTypes,
        ],
        {
          cwd: root,
          env: {
            ...process.env,
            PATH: `${bin}:${process.env.PATH}`,
            RUBY: path.join(bin, 'ruby'),
          },
          encoding: 'utf8',
        },
      );
      assert.ifError(result.error);
      assert.equal(result.status, expectedExit, result.stdout + result.stderr);
      assert.equal(
        Number(readFileSync(path.join(directory, 'devices'), 'utf8')),
        expectedDevices,
      );
      if (deviceTypes.length > 0) {
        assert.deepEqual(
          readFileSync(path.join(directory, 'created'), 'utf8')
            .trim()
            .split('\n'),
          deviceTypes,
        );
      }
      const artifacts = path.join(directory, 'artifacts/expo-bootstrap');
      const entries = readdirSync(artifacts);
      assert.equal(entries.length, 1);
      const evidence = path.join(artifacts, entries[0]);
      const ownership = parseJson(
        readFileSync(path.join(evidence, 'ownership.json'), 'utf8'),
      );
      assert.match(
        ownership.bundleIdentifier,
        /^dev\.unwired\.mock\.[0-9a-f]{32}$/u,
      );
      assert.equal(existsSync(path.join(evidence, 'Mock.app')), false);
      const deleted = new Set(
        readFileSync(path.join(directory, 'deleted'), 'utf8')
          .trim()
          .split('\n'),
      );
      assert.deepEqual(
        deleted,
        new Set(
          Array.from(
            { length: expectedDevices },
            (_, index) => `owned-${index + 1}`,
          ),
        ),
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
}
