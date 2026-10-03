/* oxlint-disable node/no-sync -- Isolated command-runner fixtures run synchronously and clean up before returning. */
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { env as inheritedEnv } from 'node:process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const sha = 'a'.repeat(40);
const number = '202610031234';
const sentinel = 'SYNTHETIC_PRIVATE_KEY_SENTINEL';

// fallow-ignore-next-line complexity -- One fixture builds the whole fake checkout and toolchain every release scenario shares.
function fixture(scenario, { dotenv = false } = {}) {
  mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
  const directory = mkdtempSync(
    path.join(root, 'scratchpad/testflight-review-'),
  );
  const checkout = path.join(directory, 'checkout with spaces');
  const bin = path.join(directory, 'bin');
  for (const folder of [
    'scripts',
    'apps/mobile/scripts',
    'apps/mobile/ios',
    'apps/macos/dist',
    'packages/mail-core/src',
  ]) {
    mkdirSync(path.join(checkout, folder), { recursive: true });
  }
  mkdirSync(bin);
  symlinkSync(process.execPath, path.join(bin, 'node'));
  const key = path.join(directory, 'AuthKey.p8');
  writeFileSync(key, 'synthetic, never used for signing');
  for (const name of ['testflight.zsh', 'testflight-env.mjs']) {
    cpSync(
      path.join(root, 'scripts', name),
      path.join(checkout, 'scripts', name),
    );
  }
  // Notes transport is tested separately with an ephemeral EC key and fake HTTP.
  writeFileSync(
    path.join(checkout, 'scripts/testflight-notes.rb'),
    `File.open(${JSON.stringify(path.join(directory, 'notes'))}, 'a') { |f| f.puts ARGV.join(' ') }\n`,
  );
  cpSync(
    path.join(root, 'apps/mobile/scripts/verify-bundle.ts'),
    path.join(checkout, 'apps/mobile/scripts/verify-bundle.ts'),
  );
  for (const name of ['index', 'theme']) {
    cpSync(
      path.join(root, `packages/mail-core/src/${name}.ts`),
      path.join(checkout, `packages/mail-core/src/${name}.ts`),
    );
  }
  for (const host of ['mobile', 'macos']) {
    writeFileSync(
      path.join(checkout, `apps/${host}/package.json`),
      JSON.stringify({ type: 'module', version: '0.1.0' }),
    );
  }
  symlinkSync(
    path.join(root, 'node_modules'),
    path.join(checkout, 'node_modules'),
  );
  let env = {
    // Keep host-wide Nix zsh initialization from replacing the stub-only PATH.
    __ETC_ZSHENV_SOURCED: '1',
    PATH: `${bin}:${inheritedEnv.PATH}`,
    HOME: directory,
    ASC_KEY_ID: 'SYNTHETIC1',
    ASC_ISSUER_ID: 'synthetic-issuer',
    ASC_KEY_PATH: key,
    ASC_PRIVATE_KEY: sentinel,
    APPLE_DEVELOPMENT_TEAM: 'SYNTHETIC1',
    UNWIRED_GOOGLE_CLIENT_ID: '123-test.apps.googleusercontent.com',
    UNWIRED_CONVEX_URL: 'https://synthetic.convex.cloud',
    UNWIRED_BUILD_NUMBER: number,
  };
  if (dotenv) {
    const fields = Object.entries(env).filter(
      ([name]) =>
        ![
          'PATH',
          'HOME',
          'ASC_PRIVATE_KEY',
          'UNWIRED_BUILD_NUMBER',
          '__ETC_ZSHENV_SOURCED',
        ].includes(name),
    );
    writeFileSync(
      path.join(checkout, '.env.local'),
      `${fields.map(([name, value]) => `${name}=${JSON.stringify(value)}`).join('\n')}\nUNRELATED_SECRET=NEVER_INHERIT\n`,
    );
    const localNames = new Set(fields.map(([name]) => name));
    env = Object.fromEntries(
      Object.entries(env).filter(([name]) => !localNames.has(name)),
    );
  }
  const stub = `#!${process.execPath}
import fs from 'node:fs';
import path from 'node:path';
const base = ${JSON.stringify(directory)};
const checkout = ${JSON.stringify(checkout)};
const scenario = ${JSON.stringify(scenario)};
const command = path.basename(process.argv[1]);
const args = process.argv.slice(2);
const value = (flag) => args[args.indexOf(flag) + 1];
const record = (name, text) => fs.appendFileSync(path.join(base, name), text + '\\n');
if (process.env.UNRELATED_SECRET) throw Error('unrelated dotenv secret reached build');
if (command === 'git' && args.includes('rev-parse')) console.log(${JSON.stringify(sha)});
if (command === 'git' && args.includes('status') && process.env.STUB_DIRTY_WORKTREE) console.log(' M tracked-file');
if (command === 'git' && args.includes('status') && process.env.STUB_GIT_FAILURE) process.exit(128);
if (command === 'pod') {
  record('commands', 'pod install');
  if (process.cwd() !== path.join(checkout, 'apps/mobile/ios')) throw Error('Expo Pods require the generated iOS project directory');
  record('pod-attempts', process.cwd());
  const attempts = fs.readFileSync(path.join(base, 'pod-attempts'), 'utf8').trim().split('\\n').length;
  if (scenario === 'pod-failure') {
    const runs = fs.readdirSync(path.join(checkout, 'artifacts/testflight'));
    for (const host of ['ios', 'macos']) {
      fs.mkdirSync(path.join(checkout, 'artifacts/testflight', runs[0], host + '-DerivedData'), { recursive: true });
    }
    process.exit(77);
  }
  if (scenario === 'pod-retry' && attempts < 3) process.exit(77);
}
if (command === 'pnpm' && args.includes('exec')) {
  const { spawnSync } = await import('node:child_process');
  const result = spawnSync(${JSON.stringify(process.execPath)}, args.slice(args.indexOf('node') + 1), { cwd: value('--dir'), env: process.env, stdio: 'inherit' });
  process.exit(result.status ?? 1);
}
if (command === 'xcodebuild') {
  record('commands', args[0]);
  if (process.env.ASC_PRIVATE_KEY) console.log(process.env.ASC_PRIVATE_KEY);
  if (args[0] === '-exportArchive') {
    if (scenario === 'export-failure') { console.log('unexpected ordinary signing failure'); process.exit(65); }
    process.exit(0);
  }
  const derived = value('-derivedDataPath');
  fs.mkdirSync(derived, { recursive: true });
  fs.writeFileSync(path.join(derived, 'owned'), '');
  if (scenario === 'archive-failure') { console.log('unexpected ordinary signing failure'); process.exit(65); }
  if (scenario === 'interrupted') { process.kill(process.ppid, 'SIGTERM'); process.exit(143); }
  if (scenario === 'missing-app') process.exit(0);
  const host = value('-archivePath').includes('macos.xcarchive') ? 'macos' : 'ios';
  const app = path.join(value('-archivePath'), 'Products/Applications/UnwiredMail.app');
  const info = path.join(app, host === 'ios' ? 'Info.plist' : 'Contents/Info.plist');
  fs.mkdirSync(path.dirname(info), { recursive: true });
  const fields = { CFBundleVersion: process.env.UNWIRED_BUILD_NUMBER, CFBundleShortVersionString: '0.1.0', CFBundleIdentifier: 'dev.unwired.mail', UnwiredCommit: process.env.UNWIRED_COMMIT, UnwiredConvexURL: process.env.UNWIRED_CONVEX_URL, GIDClientID: process.env.UNWIRED_GOOGLE_CLIENT_ID };
  if (scenario === 'mock-plist') fields.UnwiredMockScenario = 'open-read-relaunch';
  if (scenario === 'wrong-backend') fields.UnwiredConvexURL = 'https://wrong.convex.cloud';
  if (scenario === 'wrong-sha') fields.UnwiredCommit = 'b'.repeat(40);
  if (scenario === 'wrong-number') fields.CFBundleVersion = '1';
  fs.writeFileSync(info, '<?xml version="1.0"?><plist version="1.0"><dict>' + Object.entries(fields).map(([key, val]) => '<key>' + key + '</key><string>' + val + '</string>').join('') + '</dict></plist>');
  const resources = host === 'ios' ? app : path.join(app, 'Contents/Resources');
  const executable = host === 'ios' ? path.join(app, 'UnwiredMail') : path.join(app, 'Contents/MacOS/UnwiredMail');
  fs.mkdirSync(resources, { recursive: true }); fs.mkdirSync(path.dirname(executable), { recursive: true });
  fs.writeFileSync(executable, scenario === 'native-test-path' ? 'UNWIRED_LIFECYCLE_PATH' : 'Production executable');
  fs.writeFileSync(path.join(resources, 'main.jsbundle'), 'production bundle');
  const sources = ['react@19.2.3/node_modules/react/index.js', 'react-native@0.86.3/node_modules/react-native/index.js', 'effect@4.0.0-rc.118/index.js', 'expo-router/build/split-view/index.js', '/mail-core/src/index.ts', '/mail-core/src/theme.ts'];
  if (scenario === 'mock-bundle') sources.push('/mail-core/src/testing/mock.ts');
  const sourcesContent = sources.map(source => source.endsWith('/mail-core/src/index.ts') ? fs.readFileSync(path.join(checkout, 'packages/mail-core/src/index.ts'), 'utf8') : source.endsWith('/mail-core/src/theme.ts') ? fs.readFileSync(path.join(checkout, 'packages/mail-core/src/theme.ts'), 'utf8') : null);
  const map = args.find(arg => arg.startsWith('SOURCEMAP_FILE='))?.slice('SOURCEMAP_FILE='.length);
  if (map && scenario !== 'missing-map') {
    fs.mkdirSync(path.dirname(map), { recursive: true }); fs.writeFileSync(map, JSON.stringify({ sources, sourcesContent }));
    if (host === 'macos') {
      fs.copyFileSync(map, path.join(checkout, 'apps/macos/dist/main.jsbundle.map'));
      fs.writeFileSync(path.join(checkout, 'apps/macos/dist/main.jsbundle'), scenario === 'stale-mac-bundle' ? 'different bundle' : 'production bundle');
    }
  }
}
`;
  for (const command of ['pnpm', 'pod', 'git', 'xcodebuild']) {
    writeFileSync(path.join(bin, command), stub, { mode: 0o755 });
  }
  return { directory, checkout, env };
}

for (const [scenario, platform, expected] of [
  ['success', 'both', 0],
  ['success', 'ios', 0],
  ['success', 'macos', 0],
  ['pod-retry', 'ios', 0],
  ['pod-failure', 'both', 1],
  ['archive-failure', 'ios', 1],
  ['export-failure', 'ios', 1],
  ['interrupted', 'ios', 143],
  ['missing-app', 'ios', 1],
  ['mock-plist', 'ios', 1],
  ['mock-bundle', 'ios', 1],
  ['native-test-path', 'macos', 1],
  ['wrong-backend', 'ios', 1],
  ['wrong-sha', 'ios', 1],
  ['wrong-number', 'ios', 1],
  ['missing-map', 'ios', 1],
  ['stale-mac-bundle', 'macos', 1],
]) {
  test(
    `TestFlight runner protects release boundary: ${scenario}, ${platform}`,
    { skip: process.platform !== 'darwin' },
    // fallow-ignore-next-line complexity -- One table-driven case asserts every refusal and its cleanup together.
    () => {
      const { directory, checkout, env } = fixture(scenario, { dotenv: true });
      try {
        const result = spawnSync(
          '/bin/zsh',
          ['scripts/testflight.zsh', platform],
          { cwd: checkout, env, encoding: 'utf8' },
        );
        assert.equal(result.status, expected, result.stdout + result.stderr);
        const evidence = path.join(checkout, 'artifacts/testflight');
        const runs = readdirSync(evidence);
        assert.equal(runs.length, 1);
        const run = path.join(evidence, runs[0]);
        assert.ok(!existsSync(path.join(run, 'ios-DerivedData')));
        assert.ok(!existsSync(path.join(run, 'macos-DerivedData')));
        for (const file of readdirSync(run).filter((name) => {
          if (name.endsWith('.log')) {
            return true;
          }
          return name === 'status.txt';
        })) {
          assert.ok(
            !readFileSync(path.join(run, file), 'utf8').includes(sentinel),
          );
        }
        const commands = readFileSync(path.join(directory, 'commands'), 'utf8');
        if (scenario.startsWith('pod-')) {
          assert.equal(
            readFileSync(path.join(directory, 'pod-attempts'), 'utf8'),
            `${path.join(checkout, 'apps/mobile/ios')}\n`.repeat(3),
          );
        }
        if (scenario === 'pod-failure') {
          assert.equal(commands, 'pod install\npod install\npod install\n');
          const status = readFileSync(path.join(run, 'status.txt'), 'utf8');
          assert.equal(
            status,
            `Source: ${sha}; build: ${number}\nExit status: 1\n`,
          );
          assert.ok(!existsSync(path.join(directory, 'notes')));
        }
        if (expected === 0) {
          assert.ok(commands.includes('-exportArchive'));
          assert.ok(
            readFileSync(path.join(directory, 'notes'), 'utf8').includes(
              `${number} ${sha}`,
            ),
          );
        } else if (scenario !== 'export-failure') {
          assert.ok(!commands.includes('-exportArchive'));
        }
        if (scenario.endsWith('failure')) {
          assert.match(
            result.stderr,
            scenario === 'pod-failure'
              ? /CocoaPods installation failed/u
              : /Failed:/u,
          );
        }
      } finally {
        rmSync(directory, { recursive: true, force: true });
      }
    },
  );
}

test(
  'release inputs fail before generation and environment overrides dotenv data',
  { skip: process.platform !== 'darwin' },
  () => {
    const { directory, checkout, env } = fixture('success', { dotenv: true });
    try {
      for (const invalid of [
        { UNWIRED_BUILD_NUMBER: '../escape' },
        { UNWIRED_MOCK_SCENARIO: 'open-read-relaunch' },
        { APPLE_DEVELOPMENT_TEAM: '<invalid>' },
        { STUB_DIRTY_WORKTREE: '1' },
        { STUB_GIT_FAILURE: '1' },
      ]) {
        const result = spawnSync(
          '/bin/zsh',
          ['scripts/testflight.zsh', 'ios'],
          {
            cwd: checkout,
            env: { ...env, ...invalid },
            encoding: 'utf8',
          },
        );
        assert.equal(result.status, 2, result.stderr);
        assert.ok(!existsSync(path.join(directory, 'commands')));
      }
      const result = spawnSync(
        '/bin/zsh',
        ['scripts/testflight.zsh', 'bogus'],
        {
          cwd: checkout,
          env,
          encoding: 'utf8',
        },
      );
      assert.equal(result.status, 2);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  },
);

test('TestFlight notes authenticate and update the exact build without network access', () => {
  const result = spawnSync('ruby', ['scripts/testflight-notes.test.rb'], {
    cwd: root,
    env: { PATH: inheritedEnv.PATH },
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /Passed TestFlight notes contracts/u);
});
