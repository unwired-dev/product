import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const plist = (values) =>
  `<?xml version="1.0"?><plist version="1.0"><dict>${Object.entries(values)
    .map(([key, value]) => `<key>${key}</key><string>${value}</string>`)
    .join('')}</dict></plist>`;

function workspace() {
  mkdirSync(join(root, 'scratchpad'), { recursive: true });
  const directory = mkdtempSync(join(root, 'scratchpad/mock-mail-runner-'));
  mkdirSync(join(directory, 'bin'));
  return directory;
}

function run(directory, command, args, extra = {}) {
  return spawnSync(command, args, {
    cwd: directory,
    env: {
      ...process.env,
      PATH: `${join(directory, 'bin')}:${process.env.PATH}`,
      ...extra,
    },
    encoding: 'utf8',
  });
}

test('preparation refuses production builds before copying or signing', () => {
  const directory = workspace();
  try {
    const source = join(directory, 'Production.app');
    mkdirSync(source);
    writeFileSync(
      join(source, 'Info.plist'),
      plist({ CFBundleIdentifier: 'real.product' }),
    );
    const result = run(directory, 'python3', [
      join(root, 'scripts/prepare-mock-app.py'),
      'mobile',
      source,
      join(directory, 'Mock.app'),
    ]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /test-only build/u);
    assert.equal(existsSync(join(directory, 'Mock.app')), false);
    assert.equal(existsSync(join(directory, 'ownership.json')), false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

const successLog = 'Executed 1 test, with 0 failures';
const macScenarios = [
  ['success', 0, 0, successLog, 0, false],
  ['zero', 1, 0, 'Executed 0 tests, with 0 failures', 0, false],
  ['assertion', 65, 65, 'Executed 1 test, with 1 failure', 0, false],
  ['cleanup-failure', 1, 0, successLog, 1, false],
  ['terminated', 143, 143, '', 0, true],
];

for (const [scenario, expectedExit, testExit, log, cleanupExit, terminate] of macScenarios) {
  test(`Mac runner preserves evidence and cleans only its disposable resources: ${scenario}`, () => {
    const directory = workspace();
    try {
      const scripts = join(directory, 'apps/macos/scripts');
      const nativeTests = join(directory, 'apps/macos/native-tests');
      const sharedScripts = join(directory, 'scripts');
      const source = join(directory, 'Preview.app');
      for (const path of [
        scripts,
        nativeTests,
        sharedScripts,
        join(source, 'Contents'),
      ])
        mkdirSync(path, { recursive: true });
      cpSync(
        join(root, 'apps/macos/scripts/test-native.zsh'),
        join(scripts, 'test-native.zsh'),
      );
      cpSync(
        join(root, 'scripts/prepare-mock-app.py'),
        join(sharedScripts, 'prepare-mock-app.py'),
      );
      cpSync(
        join(root, 'scripts/mock-mail-scenarios.json'),
        join(sharedScripts, 'mock-mail-scenarios.json'),
      );
      writeFileSync(join(sharedScripts, 'cleanup-mock-macos.swift'), '');
      writeFileSync(join(nativeTests, 'WindowTests.swift'), '');
      writeFileSync(join(nativeTests, 'create-project.rb'), '');
      const original = plist({
        CFBundleIdentifier: 'dev.unwired.mail.macos.preview',
        UnwiredMockScenario: 'open-read-relaunch',
      });
      writeFileSync(join(source, 'Contents/Info.plist'), original);
      writeFileSync(join(directory, 'profile'), 'synthetic-profile');
      const stub = `#!${process.execPath}
import fs from 'node:fs';
import path from 'node:path';
const base = ${JSON.stringify(directory)};
const args = process.argv.slice(2);
const command = path.basename(process.argv[1]);
if (command === 'swiftc') {
  fs.writeFileSync(args[args.indexOf('-o') + 1], '#!${process.execPath}\\nimport fs from "node:fs"; fs.writeFileSync(' + JSON.stringify(path.join(base, 'cleaned')) + ', process.argv[2]); process.exit(${cleanupExit});\\n', { mode: 0o755 });
}
if (command === 'security') console.log('<?xml version="1.0"?><plist version="1.0"><dict><key>TeamIdentifier</key><array><string>SYNTHETIC</string></array><key>Entitlements</key><dict><key>com.apple.application-identifier</key><string>LEGACY1234.dev.unwired.mock.*</string></dict></dict></plist>');
if (command === 'xcodebuild') {
  if (${terminate}) { process.kill(process.ppid, 'SIGTERM'); process.exit(143); }
  console.log(${JSON.stringify(log)});
  process.exit(${testExit});
}
`;
      for (const command of [
        'ruby',
        'swiftc',
        'security',
        'codesign',
        'xcodebuild',
      ])
        writeFileSync(join(directory, 'bin', command), stub, { mode: 0o755 });
      const result = run(
        directory,
        'zsh',
        [join(scripts, 'test-native.zsh'), source],
        {
          RUBY: join(directory, 'bin/ruby'),
          UNWIRED_SIGNING_IDENTITY: 'Synthetic signer',
          UNWIRED_MOCK_PROFILE: join(directory, 'profile'),
        },
      );
      assert.ifError(result.error);
      assert.equal(
        result.status,
        expectedExit,
        result.stdout + result.stderr,
      );
      const artifacts = join(directory, 'artifacts/macos-inbox');
      const entries = readdirSync(artifacts);
      assert.equal(entries.length, 1);
      const evidence = join(artifacts, entries[0]);
      const ownership = JSON.parse(
        readFileSync(join(evidence, 'ownership.json'), 'utf8'),
      );
      assert.match(
        ownership.bundleIdentifier,
        /^dev\.unwired\.mock\.[0-9a-f]{32}$/u,
      );
      assert.equal(
        readFileSync(join(directory, 'cleaned'), 'utf8'),
        ownership.bundleIdentifier,
      );
      const entitlements = readFileSync(
        join(evidence, 'mock-entitlements.plist'),
        'utf8',
      );
      assert.ok(entitlements.includes(
        `<string>LEGACY1234.${ownership.bundleIdentifier}</string>`,
      ));
      assert.match(entitlements, /<string>SYNTHETIC<\/string>/u);
      assert.doesNotMatch(entitlements, /SYNTHETIC\.dev\.unwired\.mock/u);
      assert.equal(
        readFileSync(join(source, 'Contents/Info.plist'), 'utf8'),
        original,
      );
      assert.equal(existsSync(join(evidence, 'Mock.app')), false);
      assert.equal(
        existsSync(join(evidence, 'Cleanup.app')),
        cleanupExit !== 0,
      );
      assert.equal(
        JSON.parse(readFileSync(join(evidence, 'result.json'), 'utf8'))
          .exitCode,
        result.status,
      );
      assert.ok(existsSync(join(evidence, 'xcodebuild.log')));
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
}

test('build selection resolves only explicit test scenarios and production keeps its normal seed', () => {
  const script = `const { resolveSeed } = require('./scripts/mock-mail-build.cjs'); console.log(JSON.stringify(resolveSeed({ resolveRequest: () => ({ type: 'normal' }) }, '@private-email/mail-core/inbox-seed', 'ios')));`;
  for (const [scenario, expected] of [
    ['', 'normal'],
    ['open-read-relaunch', 'sourceFile'],
    ['mail-unavailable', 'sourceFile'],
    ['registration-cancelled', 'normal'],
    ['registration-declined', 'normal'],
    ['registration-no-gmail', 'normal'],
    ['registration-interrupted', 'normal'],
    ['registration-apple', 'normal'],
    ['registration-link', 'normal'],
  ]) {
    const result = spawnSync(process.execPath, ['-e', script], {
      cwd: root,
      env: { ...process.env, UNWIRED_MOCK_SCENARIO: scenario },
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).type, expected);
  }
  const invalid = spawnSync(process.execPath, ['-e', script], {
    cwd: root,
    env: { ...process.env, UNWIRED_MOCK_SCENARIO: '../../production' },
    encoding: 'utf8',
  });
  assert.notEqual(invalid.status, 0);
});

test('cleanup helper rejects another session before removing its storage', {
  skip: process.platform !== 'darwin',
}, () => {
  const directory = workspace();
  const identifier = 'dev.unwired.mock.' + randomUUID().replaceAll('-', '');
  const otherIdentifier = 'dev.unwired.mock.' + randomUUID().replaceAll('-', '');
  const otherStorage = join(homedir(), 'Library/Application Support', otherIdentifier);
  try {
    const contents = join(directory, 'Cleanup.app/Contents');
    mkdirSync(join(contents, 'MacOS'), { recursive: true });
    writeFileSync(join(contents, 'Info.plist'), plist({
      CFBundleIdentifier: identifier,
      CFBundleExecutable: 'cleanup',
      CFBundlePackageType: 'APPL',
    }));
    const executable = join(contents, 'MacOS/cleanup');
    const build = run(directory, 'swiftc', [
      join(root, 'scripts/cleanup-mock-macos.swift'), '-o', executable,
    ]);
    assert.equal(build.status, 0, build.stdout + build.stderr);
    mkdirSync(otherStorage);
    const sentinel = join(otherStorage, 'sentinel');
    writeFileSync(sentinel, 'another session');
    for (const args of [[], [otherIdentifier]]) {
      const result = run(directory, executable, args);
      assert.ifError(result.error);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /Expected this helper|Refusing cleanup outside/u);
      assert.equal(readFileSync(sentinel, 'utf8'), 'another session');
    }
    // The unsigned helper can reach the Keychain boundary for its own session.
    const ownSession = run(directory, executable, [identifier]);
    assert.ifError(ownSession.error);
    assert.doesNotMatch(ownSession.stderr, /Expected this helper|Refusing cleanup outside/u);
    assert.equal(readFileSync(sentinel, 'utf8'), 'another session');
  } finally {
    rmSync(otherStorage, { recursive: true, force: true });
    rmSync(directory, { recursive: true, force: true });
  }
});
