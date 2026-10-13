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
import path from 'node:path';
import { env as inheritedEnv } from 'node:process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));

// Runs the Mac build script against stubbed pnpm, ruby and xcodebuild; `failures` is how
// many pod installs fail before one succeeds.
function build(t, failures) {
  mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
  const directory = mkdtempSync(path.join(root, 'scratchpad/build-native-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const checkout = path.join(directory, 'checkout');
  const bin = path.join(directory, 'bin');
  mkdirSync(path.join(checkout, 'apps/macos/scripts'), { recursive: true });
  mkdirSync(path.join(checkout, 'native/private-inbox'), { recursive: true });
  mkdirSync(bin);
  cpSync(
    path.join(root, 'apps/macos/scripts/build-native.zsh'),
    path.join(checkout, 'apps/macos/scripts/build-native.zsh'),
  );
  writeFileSync(
    path.join(checkout, 'native/private-inbox/Package.resolved'),
    '{}',
  );
  const log = path.join(directory, 'commands');
  const stub = `#!${process.execPath}
import fs from 'node:fs';
import path from 'node:path';
const command = path.basename(process.argv[1]);
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, [command, ...args].join(' ') + '\\n');
if (command === 'ruby') process.stdout.write(${JSON.stringify(bin)});
if (command === 'pnpm' && args[0] === 'native:pods') {
  const attempts = fs.readFileSync(${JSON.stringify(log)}, 'utf8').split('\\n').filter((line) => line === 'pnpm native:pods').length;
  if (attempts <= ${failures}) process.exit(77);
}
`;
  for (const name of ['pnpm', 'ruby', 'xcodebuild']) {
    writeFileSync(path.join(bin, name), stub, { mode: 0o755 });
  }
  const result = spawnSync(
    '/bin/zsh',
    [path.join(checkout, 'apps/macos/scripts/build-native.zsh'), 'Debug'],
    {
      cwd: checkout,
      encoding: 'utf8',
      env: {
        // Keep host-wide Nix zsh initialization from replacing the stub-only PATH.
        __ETC_ZSHENV_SOURCED: '1',
        PATH: `${bin}:${inheritedEnv.PATH}`,
        HOME: directory,
        UNWIRED_DEVELOPMENT_TEAM: 'SYNTHETIC1',
      },
    },
  );
  const commands = readFileSync(log, 'utf8').trim().split('\n');
  return { ...result, commands };
}

test('a failed pod install is repeated, then the signed build runs', (t) => {
  const { status, commands } = build(t, 1);
  assert.equal(status, 0);
  assert.equal(
    commands.filter((line) => line === 'pnpm native:pods').length,
    2,
  );
  const xcodebuild = commands.filter((line) => line.startsWith('xcodebuild '));
  assert.equal(xcodebuild.length, 1);
  assert.match(
    xcodebuild[0],
    / CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=SYNTHETIC1 /u,
  );
});

test('three failed pod installs stop the build', (t) => {
  const { status, stderr, commands } = build(t, 3);
  assert.equal(status, 1);
  assert.match(stderr, /CocoaPods installation failed/u);
  assert.equal(
    commands.filter((line) => line === 'pnpm native:pods').length,
    3,
  );
  assert.ok(!commands.some((line) => line.startsWith('xcodebuild ')));
});
