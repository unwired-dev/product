import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';

import * as Schema from 'effect/Schema';

const decodeJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);

const root = path.join(import.meta.dirname, '..');
const script = path.join(root, 'scripts/native-licence-inventory.mjs');

const write = (file, text = '') => {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, text);
};

const specifier = (title, licence) =>
  `<dict><key>Title</key><string>${title}</string>${
    licence ? `<key>License</key><string>${licence}</string>` : ''
  }</dict>`;

// An installed Pods folder with a remote pod CocoaPods acknowledged, path pods
// with string, object and missing podspec licences, and a remote pod without
// licence text; path pods whose npm package root, own directory or neither
// ships a licence (a LICENSE folder is not one), and a podspec-sourced pod in a
// licensed package that also names it as a path; resolved
// Swift packages pinned by version and by revision.
function fixture() {
  mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
  const directory = mkdtempSync(
    path.join(root, 'scratchpad/native-licence-inventory-'),
  );
  write(path.join(directory, 'package.json'), '{}');
  write(path.join(directory, 'node_modules/react-native/package.json'), '{}');
  write(path.join(directory, 'node_modules/react-native/LICENSE'));
  write(
    path.join(
      directory,
      'node_modules/react-native/ReactCommon/yoga/Yoga.podspec',
    ),
  );
  write(path.join(directory, 'node_modules/expo-font/package.json'), '{}');
  write(path.join(directory, 'node_modules/expo-font/ios/LICENSE.md'));
  write(path.join(directory, 'ios/build/generated/ios/ReactCodegen.podspec'));
  mkdirSync(path.join(directory, 'ios/build/generated/ios/LICENSE'));
  const pods = path.join(directory, 'ios/Pods');
  write(
    path.join(pods, 'Manifest.lock'),
    [
      'PODS:',
      '  - AppAuth (3.0.0):',
      '    - AppAuth/Core (= 3.0.0)',
      '  - AppAuth/Core (3.0.0)',
      '  - DoubleConversion (1.1.6)',
      '  - ExpoFont (58.0.11)',
      '  - "GoogleUtilities/NSData+zlib (8.1.4)":',
      '    - GoogleUtilities/Environment',
      '  - React-Core (0.81.9)',
      '  - RCT-Folly (2024.11.18.00)',
      '  - ReactCodegen (0.81.9)',
      '  - Yoga (0.0.0)',
      '',
      'DEPENDENCIES:',
      '  - "React-Core (from `../node_modules/react-native/`)"',
      '',
      'EXTERNAL SOURCES:',
      '  DoubleConversion:',
      '    :path: "../node_modules/react-native"',
      '    :podspec: "../node_modules/react-native/third-party-podspecs/DoubleConversion.podspec"',
      '  ExpoFont:',
      '    :path: "../node_modules/expo-font/ios"',
      '  React-Core:',
      '    :path: "../node_modules/react-native/"',
      '  ReactCodegen:',
      "    :path: 'build/generated/ios'",
      '  Yoga:',
      '    :path: "../node_modules/react-native/ReactCommon/yoga"',
      '',
      'COCOAPODS: 1.17.0',
      '',
    ].join('\n'),
  );
  write(
    path.join(
      pods,
      'Target Support Files/Pods-UnwiredMail/Pods-UnwiredMail-acknowledgements.plist',
    ),
    `<?xml version="1.0"?><plist version="1.0"><dict><key>PreferenceSpecifiers</key><array>${[
      specifier('Acknowledgements'),
      specifier('AppAuth', 'Apache-2.0'),
      specifier('RCT-Folly', 'Apache License, Version 2.0'),
      specifier(''),
    ].join('')}</array></dict></plist>`,
  );
  const podspec = (name, spec) =>
    write(
      path.join(pods, 'Local Podspecs', `${name}.podspec.json`),
      JSON.stringify({ name, ...spec }),
    );
  podspec('DoubleConversion', { license: 'BSD' });
  podspec('ExpoFont', { license: 'MIT' });
  podspec('React-Core', { license: 'MIT' });
  podspec('ReactCodegen', { license: 'MIT' });
  podspec('RCT-Folly', { license: { type: 'Apache License, Version 2.0' } });
  podspec('Yoga', {});
  const packages = path.join(directory, 'SourcePackages');
  const dependency = (identity, checkoutState, ...files) => {
    for (const file of ['Package.swift', ...files]) {
      write(path.join(packages, 'checkouts', identity, file));
    }
    return {
      packageRef: {
        identity,
        kind: 'remoteSourceControl',
        location: `https://github.com/example/${identity}.git`,
      },
      state: { checkoutState, name: 'sourceControlCheckout' },
      subpath: identity,
    };
  };
  const state = path.join(packages, 'workspace-state.json');
  write(
    state,
    JSON.stringify({
      object: {
        dependencies: [
          dependency(
            'swift-nio',
            { revision: 'a'.repeat(40), version: '2.80.0' },
            'NOTICE.txt',
            'LICENSE.txt',
          ),
          dependency('sentry-cocoa', { revision: 'b'.repeat(40) }),
        ],
      },
      version: 7,
    }),
  );
  return { directory, pods, packages, state };
}

const inventory = (pods, packages) =>
  spawnSync(process.execPath, [script, pods, packages], { encoding: 'utf8' });

// The acknowledgements are a property list, read with macOS plutil.
test(
  'native licence inventory records pods and Swift packages',
  { skip: process.platform !== 'darwin' },
  () => {
    const { directory, pods, packages, state } = fixture();
    try {
      const result = inventory(pods, packages);
      assert.equal(result.status, 0, result.stderr);
      assert.deepEqual(decodeJson(result.stdout), {
        pods: [
          {
            name: 'AppAuth',
            version: '3.0.0',
            licence: 'Apache-2.0',
            licenceText: true,
          },
          {
            name: 'DoubleConversion',
            version: '1.1.6',
            licence: 'BSD',
            licenceText: false,
          },
          {
            name: 'ExpoFont',
            version: '58.0.11',
            licence: 'MIT',
            licenceText: true,
          },
          {
            name: 'GoogleUtilities',
            version: '8.1.4',
            licence: null,
            licenceText: false,
          },
          {
            name: 'RCT-Folly',
            version: '2024.11.18.00',
            licence: 'Apache License, Version 2.0',
            licenceText: true,
          },
          {
            name: 'React-Core',
            version: '0.81.9',
            licence: 'MIT',
            licenceText: true,
          },
          {
            name: 'ReactCodegen',
            version: '0.81.9',
            licence: 'MIT',
            licenceText: false,
          },
          { name: 'Yoga', version: '0.0.0', licence: null, licenceText: true },
        ],
        swiftPackages: [
          {
            identity: 'sentry-cocoa',
            location: 'https://github.com/example/sentry-cocoa.git',
            version: null,
            revision: 'b'.repeat(40),
            licenceFiles: [],
          },
          {
            identity: 'swift-nio',
            location: 'https://github.com/example/swift-nio.git',
            version: '2.80.0',
            revision: 'a'.repeat(40),
            licenceFiles: ['LICENSE.txt', 'NOTICE.txt'],
          },
        ],
        undeclared: ['GoogleUtilities@8.1.4', 'Yoga@0.0.0'],
        withoutLicenceText: [
          'DoubleConversion@1.1.6',
          'GoogleUtilities@8.1.4',
          'ReactCodegen@0.81.9',
          `sentry-cocoa@${'b'.repeat(40)}`,
        ],
      });

      rmSync(path.join(directory, 'node_modules/expo-font'), {
        recursive: true,
      });
      const missingPath = inventory(pods, packages);
      assert.equal(missingPath.status, 1);
      assert.match(
        missingPath.stderr,
        /missing pod path .*node_modules\/expo-font\/ios/u,
      );
      assert.equal(missingPath.stdout, '');
      write(path.join(directory, 'node_modules/expo-font/ios/LICENSE.md'));

      rmSync(path.join(packages, 'checkouts/swift-nio'), { recursive: true });
      const missing = inventory(pods, packages);
      assert.equal(missing.status, 1);
      assert.match(missing.stderr, /missing checkout .*checkouts\/swift-nio/u);
      assert.equal(missing.stdout, '');

      writeFileSync(state, '{"object": {"dependencies": [{}]}}');
      assert.match(
        inventory(pods, packages).stderr,
        /unreadable .*workspace-state\.json/u,
      );
      writeFileSync(path.join(pods, 'Manifest.lock'), 'COCOAPODS: 1.17.0\n');
      assert.match(
        inventory(pods, packages).stderr,
        /unreadable .*Manifest\.lock: no PODS section/u,
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  },
);
