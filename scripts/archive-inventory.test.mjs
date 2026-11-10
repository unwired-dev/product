import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import test from 'node:test';

import * as Schema from 'effect/Schema';

const decodeJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);

const root = path.join(import.meta.dirname, '..');
const script = path.join(root, 'scripts/archive-inventory.mjs');

const plist = (body) =>
  `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>${body}</dict></plist>`;
const api = (category, ...reasons) =>
  `<dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategory${category}</string><key>NSPrivacyAccessedAPITypeReasons</key><array>${reasons.map((reason) => `<string>${reason}</string>`).join('')}</array></dict>`;
const manifest = (...apis) =>
  plist(
    `<key>NSPrivacyTracking</key><false/><key>NSPrivacyAccessedAPITypes</key><array>${apis.join('')}</array>`,
  );

// An iOS-layout archive: one framework with a manifest, nested inside one
// without, and one unsigned.
function fixture() {
  const directory = mkdtempSync(
    path.join(root, 'scratchpad/archive-inventory-'),
  );
  const app = path.join(
    directory,
    'Unwired.xcarchive/Products/Applications/UnwiredMail.app',
  );
  const bundle = (relative, identifier, executable) => {
    const folder = path.join(app, relative);
    mkdirSync(folder, { recursive: true });
    copyFileSync('/usr/bin/true', path.join(folder, executable));
    writeFileSync(
      path.join(folder, 'Info.plist'),
      plist(
        `<key>CFBundleIdentifier</key><string>${identifier}</string><key>CFBundleExecutable</key><string>${executable}</string><key>CFBundleShortVersionString</key><string>0.1.0</string><key>CFBundleVersion</key><string>42</string><key>UnwiredCommit</key><string>${'a'.repeat(40)}</string><key>NSCameraUsageDescription</key><string>Attach photos.</string><key>ITSAppUsesNonExemptEncryption</key><false/>`,
      ),
    );
    return folder;
  };
  const sign = (folder, entitlements) => {
    const args = ['-f', '-s', '-'];
    if (entitlements) {
      writeFileSync(path.join(directory, 'entitlements.plist'), entitlements);
      args.push('--entitlements', path.join(directory, 'entitlements.plist'));
    }
    execFileSync('codesign', [...args, folder], { stdio: 'ignore' });
  };
  const tracked = bundle(
    'Frameworks/Untracked.framework/Frameworks/Tracked.framework',
    'dev.example.tracked',
    'Tracked',
  );
  mkdirSync(path.join(tracked, 'Tracked.bundle'));
  writeFileSync(
    path.join(tracked, 'Tracked.bundle/PrivacyInfo.xcprivacy'),
    manifest(api('UserDefaults', 'C56D.1'), api('FileTimestamp', 'C617.1')),
  );
  // Links CryptoKit and Security, imports CommonCrypto and SecKey and, once
  // stripped, keeps BoringSSL's error format string and OpenSSL's version string.
  writeFileSync(
    path.join(directory, 'crypto.c'),
    '#include <CommonCrypto/CommonDigest.h>\n#include <Security/Security.h>\n#include <stdio.h>\nint main(int argc, char **argv) { unsigned char digest[32]; CC_SHA256("", 0, digest); if (argc > 1) printf("error:%08x:%s:OPENSSL_internal:%s", 0, "", ""); if (argc > 2) puts("OpenSSL 3.0.13 30 Jan 2024"); return SecKeyCreateRandomKey(NULL, NULL) != NULL; }\n',
  );
  execFileSync('clang', [
    path.join(directory, 'crypto.c'),
    '-w',
    '-o',
    path.join(tracked, 'Tracked'),
    '-framework',
    'Security',
    '-framework',
    'CryptoKit',
  ]);
  execFileSync('strip', [path.join(tracked, 'Tracked')]);
  // Versioned Mac frameworks link directories; the walk must list them once.
  symlinkSync('Tracked.bundle', path.join(tracked, 'Current'));
  sign(tracked);
  sign(
    bundle(
      'Frameworks/Untracked.framework',
      'dev.example.untracked',
      'Untracked',
    ),
  );
  // The copied executable keeps Apple's signature until it is removed.
  const unsigned = bundle(
    'Frameworks/Unsigned.framework',
    'dev.example.unsigned',
    'Unsigned',
  );
  execFileSync('codesign', [
    '--remove-signature',
    path.join(unsigned, 'Unsigned'),
  ]);
  bundle('.', 'dev.unwired.mail', 'UnwiredMail');
  writeFileSync(
    path.join(app, 'PrivacyInfo.xcprivacy'),
    manifest(api('UserDefaults', 'CA92.1', 'C56D.1')),
  );
  sign(
    app,
    plist(
      '<key>com.apple.developer.applesignin</key><array><string>Default</string></array>',
    ),
  );
  return { directory, app };
}

const inventory = (target) =>
  spawnSync(process.execPath, [script, target], { encoding: 'utf8' });

test(
  'archive inventory records manifests, permissions, entitlements and cryptography',
  { skip: process.platform !== 'darwin' },
  () => {
    mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
    const { directory, app } = fixture();
    try {
      const archive = path.join(directory, 'Unwired.xcarchive');
      const result = inventory(archive);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(inventory(app).stdout, result.stdout);
      assert.equal(inventory(`${archive}/`).stdout, result.stdout);
      const report = decodeJson(result.stdout);
      assert.deepEqual(report.build, {
        bundleId: 'dev.unwired.mail',
        version: '0.1.0',
        buildNumber: '42',
        commit: 'a'.repeat(40),
        platform: 'ios',
      });
      assert.deepEqual(report.encryption, {
        usesNonExemptEncryption: false,
        exportComplianceCode: null,
      });
      assert.deepEqual(
        report.privacyManifests.map((entry) => entry.path),
        [
          'Frameworks/Untracked.framework/Frameworks/Tracked.framework/Tracked.bundle/PrivacyInfo.xcprivacy',
          'PrivacyInfo.xcprivacy',
        ],
      );
      assert.deepEqual(report.requiredReasonApis, {
        NSPrivacyAccessedAPICategoryFileTimestamp: ['C617.1'],
        NSPrivacyAccessedAPICategoryUserDefaults: ['C56D.1', 'CA92.1'],
      });
      assert.deepEqual(report.permissions, {
        NSCameraUsageDescription: 'Attach photos.',
      });
      assert.deepEqual(
        report.code.map(({ path: entry, entitlements }) => [
          entry,
          entitlements,
        ]),
        [
          ['.', { 'com.apple.developer.applesignin': ['Default'] }],
          ['Frameworks/Unsigned.framework', 'unsigned'],
          ['Frameworks/Untracked.framework', {}],
          ['Frameworks/Untracked.framework/Frameworks/Tracked.framework', {}],
        ],
      );
      assert.deepEqual(report.withoutPrivacyManifest, [
        'Frameworks/Unsigned.framework',
        'Frameworks/Untracked.framework',
      ]);
      const none = { libraries: [], imports: [], bundled: [] };
      assert.deepEqual(
        report.code.map(({ cryptography }) => cryptography),
        [
          none,
          none,
          none,
          {
            libraries: [
              '/System/Library/Frameworks/CryptoKit.framework/Versions/A/CryptoKit',
              '/System/Library/Frameworks/Security.framework/Versions/A/Security',
            ],
            imports: ['_CC_SHA256', '_SecKeyCreateRandomKey'],
            bundled: [
              'OpenSSL 3.0.13 30 Jan 2024',
              'error:%08x:%s:OPENSSL_internal:%s',
            ],
          },
        ],
      );

      writeFileSync(
        path.join(app, 'Frameworks/Unsigned.framework/Unsigned'),
        'unreadable',
      );
      const executable = inventory(archive);
      assert.equal(executable.status, 1);
      assert.match(
        executable.stderr,
        /nm failed for .*Unsigned\.framework\/Unsigned/u,
      );
      assert.equal(executable.stdout, '');

      writeFileSync(path.join(app, 'PrivacyInfo.xcprivacy'), 'unreadable');
      const unreadable = inventory(archive);
      assert.equal(unreadable.status, 1);
      assert.match(
        unreadable.stderr,
        /unreadable property list .*UnwiredMail\.app\/PrivacyInfo\.xcprivacy/u,
      );
      assert.equal(unreadable.stdout, '');

      rmSync(path.join(app, 'PrivacyInfo.xcprivacy'));
      symlinkSync('Missing.xcprivacy', path.join(app, 'PrivacyInfo.xcprivacy'));
      const dangling = inventory(archive);
      assert.equal(dangling.status, 1);
      assert.equal(dangling.stdout, '');
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  },
);
