import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const scenarios = [
  ['success', 0, 2],
  ['multiple-tests', 0, 2],
  ['no-results', 1, 1],
  ['assertion-with-connection-log', 1, 1],
  ['assertion-with-infrastructure-error', 1, 1],
  ['socket', 0, 3],
  ['disconnect', 0, 3],
  ['zero', 0, 3],
  ['persistent', 1, 2],
  ['assertion', 1, 1],
];

for (const [scenario, expectedExit, expectedDevices] of scenarios) {
  test(`native runner: ${scenario}`, () => {
    mkdirSync(join(root, 'scratchpad'), { recursive: true });
    const directory = mkdtempSync(join(root, 'scratchpad/native-runner-'));
    try {
      const scripts = join(directory, 'apps/mobile/scripts');
      const nativeTests = join(directory, 'apps/mobile/native-tests');
      const bin = join(directory, 'bin');
      for (const path of [
        scripts,
        nativeTests,
        bin,
        join(directory, 'Preview.app'),
      ]) {
        mkdirSync(path, { recursive: true });
      }
      cpSync(
        join(root, 'apps/mobile/scripts/test-native.zsh'),
        join(scripts, 'test-native.zsh'),
      );
      writeFileSync(join(nativeTests, 'InboxTests.swift'), '');
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
if (command === 'xcrun' && args[1] === 'create') console.log('owned-' + next('devices'));
if (command === 'xcrun' && args[1] === 'delete') fs.appendFileSync(path.join(base, 'deleted'), args[2] + '\\n');
if (command === 'xcodebuild' && args[0] === 'test-without-building') {
  const attempt = next('attempts');
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
      for (const command of ['xcrun', 'xcodebuild', 'ruby']) {
        writeFileSync(join(bin, command), stub, { mode: 0o755 });
      }
      const result = spawnSync(
        'zsh',
        [join(scripts, 'test-native.zsh'), join(directory, 'Preview.app')],
        {
          cwd: root,
          env: {
            ...process.env,
            PATH: `${bin}:${process.env.PATH}`,
            RUBY: join(bin, 'ruby'),
          },
          encoding: 'utf8',
        },
      );
      assert.ifError(result.error);
      assert.equal(result.status, expectedExit, result.stdout + result.stderr);
      assert.equal(
        Number(readFileSync(join(directory, 'devices'), 'utf8')),
        expectedDevices,
      );
      const deleted = new Set(
        readFileSync(join(directory, 'deleted'), 'utf8').trim().split('\n'),
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
