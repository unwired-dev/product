// Protect distribution notices against silently dropping vendor terms or
// presenting an unresolved component as complete.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import test from 'node:test';

import * as Schema from 'effect/Schema';

import thirdPartyNotices from '../apps/mobile/plugins/third-party-notices.cjs';

const decode = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);
const root = path.join(import.meta.dirname, '..');
const script = path.join(import.meta.dirname, 'third-party-notices.mjs');
const write = (file, text) => {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, text);
};

test(
  'packages exact installed notice text and reports missing parent terms',
  { skip: process.platform !== 'darwin' },
  () => {
    const directory = mkdtempSync(path.join(root, 'scratchpad/notices-'));
    try {
      const npm = path.join(directory, 'node_modules/example');
      write(
        path.join(npm, 'package.json'),
        JSON.stringify({ name: 'example', version: '1.0.0', license: 'MIT' }),
      );
      write(
        path.join(npm, 'vendor/LICENSE'),
        'Vendor copyright and permission\n',
      );
      write(
        path.join(npm, 'THIRD_PARTY_NOTICES.md'),
        'Bundled npm vendor notice',
      );
      const map = path.join(directory, 'bundle.map');
      write(map, JSON.stringify({ sources: [path.join(npm, 'index.js')] }));
      const pods = path.join(directory, 'ios/Pods');
      write(
        path.join(pods, 'Manifest.lock'),
        'PODS:\n  - ExamplePod (1.0.0)\n\n',
      );
      write(
        path.join(
          pods,
          'Target Support Files/Pods-UnwiredMail/Pods-UnwiredMail-acknowledgements.plist',
        ),
        '<plist version="1.0"><dict><key>PreferenceSpecifiers</key><array><dict><key>Title</key><string>ExamplePod</string><key>License</key><string>MIT</string><key>FooterText</key><string>Pod copyright and permission</string></dict></array></dict></plist>',
      );
      const swift = path.join(directory, 'SourcePackages');
      write(
        path.join(swift, 'workspace-state.json'),
        JSON.stringify({
          object: {
            dependencies: [
              {
                packageRef: {
                  identity: 'example-swift',
                  location: 'https://example.com/swift',
                },
                state: {
                  checkoutState: { revision: 'abcdef', version: '1.0.0' },
                },
                subpath: 'example-swift',
              },
            ],
          },
        }),
      );
      write(
        path.join(swift, 'checkouts/example-swift/LICENSE'),
        'Swift copyright and permission',
      );
      write(
        path.join(swift, 'checkouts/example-swift/THIRD_PARTY_NOTICES.md'),
        'KSCrash, fishhook and Apple vendor terms',
      );
      const output = path.join(directory, 'resources');
      const result = spawnSync(
        process.execPath,
        [script, map, pods, swift, output],
        { encoding: 'utf8' },
      );
      assert.equal(result.status, 0, result.stderr);
      const text = readFileSync(
        path.join(output, 'ThirdPartyNotices.txt'),
        'utf8',
      );
      assert.match(text, /Vendor copyright and permission/u);
      assert.match(text, /Pod copyright and permission/u);
      assert.match(text, /Swift copyright and permission/u);
      assert.match(text, /KSCrash, fishhook and Apple vendor terms/u);
      assert.match(text, /Bundled npm vendor notice/u);
      const report = decode(
        readFileSync(path.join(output, 'ThirdPartyNotices.json'), 'utf8'),
      );
      assert.deepEqual(report.unresolved, ['npm:example@1.0.0']);
      assert.equal(report.components.length, 3);
      assert.ok(!text.includes(directory));
      write(path.join(npm, 'LICENSE'), 'Main copyright and permission');
      const resolved = spawnSync(
        process.execPath,
        [script, map, pods, swift, output],
        { encoding: 'utf8' },
      );
      assert.equal(resolved.status, 0, resolved.stderr);
      assert.deepEqual(
        decode(
          readFileSync(path.join(output, 'ThirdPartyNotices.json'), 'utf8'),
        ).unresolved,
        [],
      );
      const stateFile = path.join(swift, 'workspace-state.json');
      const originalState = readFileSync(stateFile, 'utf8');
      const unknown = decode(originalState);
      unknown.object.dependencies[0].packageRef.identity = 'swift-nio-ssl';
      unknown.object.dependencies[0].state.checkoutState.version = '99.0.0';
      write(stateFile, JSON.stringify(unknown));
      assert.equal(
        spawnSync(process.execPath, [script, map, pods, swift, output], {
          encoding: 'utf8',
        }).status,
        0,
      );
      assert.deepEqual(
        decode(
          readFileSync(path.join(output, 'ThirdPartyNotices.json'), 'utf8'),
        ).unresolved,
        ['swift:swift-nio-ssl@99.0.0'],
      );
      write(stateFile, originalState);
      const tools = path.join(directory, 'tools');
      mkdirSync(tools, { recursive: true });
      for (const file of [
        'third-party-notices.mjs',
        'licence-inventory.mjs',
        'native-licence-inventory.mjs',
        'notice-files.mjs',
      ]) {
        copyFileSync(path.join(root, 'scripts', file), path.join(tools, file));
      }
      write(
        path.join(tools, 'third-party-licences/index.json'),
        JSON.stringify([
          {
            ecosystem: 'npm',
            name: 'example',
            version: '1.0.0',
            file: 'LICENSE',
            url: 'https://example.com/pinned',
            role: 'root',
            sha256: 'incorrect',
          },
        ]),
      );
      write(path.join(tools, 'third-party-licences/LICENSE'), 'tampered terms');
      const tampered = spawnSync(
        process.execPath,
        [path.join(tools, 'third-party-notices.mjs'), map, pods, swift, output],
        { encoding: 'utf8' },
      );
      assert.notEqual(tampered.status, 0);
      assert.match(tampered.stderr, /supplement hash mismatch/u);
      const guarded = [
        {
          ecosystem: 'npm',
          name: 'example',
          version: '1.0.0',
          file: 'LICENSE',
          url: 'https://example.com/guarded',
          role: 'vendor',
          sha256: createHash('sha256').update('Guarded terms').digest('hex'),
          requires: [
            { ecosystem: 'pod', name: 'ExamplePod', version: '2.0.0' },
          ],
        },
      ];
      write(path.join(tools, 'third-party-licences/LICENSE'), 'Guarded terms');
      write(
        path.join(tools, 'third-party-licences/index.json'),
        JSON.stringify(guarded),
      );
      const runGuarded = () =>
        spawnSync(
          process.execPath,
          [
            path.join(tools, 'third-party-notices.mjs'),
            map,
            pods,
            swift,
            output,
          ],
          { encoding: 'utf8' },
        );
      assert.equal(runGuarded().status, 0);
      assert.ok(
        !readFileSync(
          path.join(output, 'ThirdPartyNotices.txt'),
          'utf8',
        ).includes('Guarded terms'),
      );
      guarded[0].requires[0].version = '1.0.0';
      write(
        path.join(tools, 'third-party-licences/index.json'),
        JSON.stringify(guarded),
      );
      assert.equal(runGuarded().status, 0);
      assert.ok(
        readFileSync(
          path.join(output, 'ThirdPartyNotices.txt'),
          'utf8',
        ).includes('Guarded terms'),
      );
      write(map, 'invalid json');
      assert.notEqual(
        spawnSync(process.execPath, [script, map, pods, swift, output], {
          encoding: 'utf8',
        }).status,
        0,
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  },
);

test('pinned licence source bytes remain intact', () => {
  const directory = path.join(root, 'scripts/third-party-licences');
  for (const entry of decode(
    readFileSync(path.join(directory, 'index.json'), 'utf8'),
  )) {
    const text = readFileSync(path.join(directory, entry.file));
    assert.ok(text.length > 0, entry.file);
    assert.equal(
      createHash('sha256').update(text).digest('hex'),
      entry.sha256,
      entry.file,
    );
  }
});

test('mobile bundle failure cannot be replaced by a successful notice command', async () => {
  const directory = mkdtempSync(path.join(root, 'scratchpad/notice-phase-'));
  try {
    const phase = {
      name: '"Bundle React Native code and images"',
      shellScript: JSON.stringify('/bin/sh "$BUNDLER_SCRIPT"'),
    };
    const apply = async () => {
      const config = thirdPartyNotices({ name: 'Fixture', slug: 'fixture' });
      await config.mods.ios.xcodeproj({
        ...config,
        modRequest: { platform: 'ios', modName: 'xcodeproj' },
        modResults: {
          hash: {
            project: { objects: { PBXShellScriptBuildPhase: { phase } } },
          },
        },
      });
    };
    await apply();
    await apply();
    const phaseScript = Schema.decodeSync(Schema.fromJsonString(Schema.String))(
      phase.shellScript,
    );
    const marker = path.join(directory, 'notice-generated');
    const bundler = path.join(directory, 'bundler.sh');
    const derived = path.join(directory, 'derived');
    // A preceding build left a usable source map. Successful notice generation
    // must still be unreachable when the next Metro/Hermes process fails.
    write(path.join(derived, 'Unwired-main.jsbundle.map'), '{"sources":[]}');
    write(
      path.join(directory, 'scripts/bundle-third-party-notices.sh'),
      'printf generated > "$NOTICES_MARKER"',
    );
    const run = () =>
      spawnSync('/bin/sh', ['-c', phaseScript], {
        encoding: 'utf8',
        env: {
          ...process.env,
          SRCROOT: path.join(directory, 'apps/mobile/ios'),
          DERIVED_FILE_DIR: derived,
          BUNDLER_SCRIPT: bundler,
          NOTICES_MARKER: marker,
        },
      });
    mkdirSync(path.join(directory, 'apps/mobile/ios'), { recursive: true });
    write(bundler, 'exit 17');
    assert.equal(run().status, 17);
    assert.equal(existsSync(marker), false);
    write(bundler, 'exit 0');
    assert.equal(run().status, 0);
    assert.equal(readFileSync(marker, 'utf8'), 'generated');
    assert.equal(phaseScript.split('# Unwired third-party notices').length, 2);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
