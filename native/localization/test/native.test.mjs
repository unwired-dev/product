/* oxlint-disable node/no-sync -- Serial native process launches verify preferences after process exit. */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../../', import.meta.url));

test('Apple language matching, native fallback, and override persistence across launches', () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'unwired-localization-'));
  const contents = path.join(directory, 'Probe.app/Contents');
  const binary = path.join(contents, 'MacOS/Probe');
  const resources = path.join(contents, 'Resources/catalogs.bundle');
  mkdirSync(path.dirname(binary), { recursive: true });
  mkdirSync(resources, { recursive: true });
  writeFileSync(
    path.join(contents, 'Info.plist'),
    `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.unwired.localization-test.${randomUUID()}</string><key>CFBundleExecutable</key><string>Probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`,
  );
  cpSync(path.join(root, 'packages/localization/catalogs.bundle'), resources, {
    recursive: true,
  });
  const run = (...args) =>
    JSON.parse(execFileSync(binary, args, { encoding: 'utf8' }));
  let compiled = false;
  try {
    execFileSync('xcrun', [
      'clang',
      '-fobjc-arc',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-Wno-unused-parameter',
      '-framework',
      'Foundation',
      '-I',
      path.join(root, 'native/localization'),
      path.join(root, 'native/localization/UnwiredLanguagePreferences.m'),
      path.join(root, 'native/localization/test/Probe.m'),
      '-o',
      binary,
    ]);
    compiled = true;
    const unsupported = run('-AppleLanguages', '(de-DE)');
    assert.equal(unsupported.settings.language, 'en');
    assert.equal(unsupported.settings.preference, null);
    assert.equal(unsupported.showInbox, 'Show Inbox');

    // A test-only catalog proves future regional matching and per-key fallback.
    writeFileSync(
      path.join(resources, 'languages.json'),
      JSON.stringify([
        { code: 'en', name: 'English' },
        { code: 'fr', name: 'Français' },
      ]),
    );
    writeFileSync(
      path.join(resources, 'fr.json'),
      JSON.stringify({
        native: { showInbox: 'Afficher la boîte de réception' },
      }),
    );
    const french = [
      '-AppleLanguages',
      '(de-DE, fr-CA)',
      '-AppleLocale',
      'fr_CA',
    ];
    const regional = run('-AppleLocale', 'en_US@rg=czzzzz');
    assert.equal(regional.settings.locale, 'en-CZ');
    assert.doesNotThrow(() =>
      new Intl.DateTimeFormat(regional.settings.locale).format(new Date(0)),
    );
    const system = run(...french);
    assert.equal(system.settings.language, 'fr');
    assert.equal(system.settings.locale, 'fr-CA');
    assert.equal(system.showInbox, 'Afficher la boîte de réception');
    assert.equal(system.hide, 'Hide Unwired Mail');
    run('--english', ...french);
    const relaunched = run(...french);
    assert.deepEqual(relaunched.settings, {
      preference: 'en',
      language: 'en',
      locale: 'en',
    });
    assert.equal(relaunched.showInbox, 'Show Inbox');
    const restored = run('--system', ...french);
    assert.equal(restored.settings.preference, null);
    assert.equal(restored.settings.language, 'fr');
    assert.equal(restored.showInbox, system.showInbox);
    const removedLocale = run('-interfaceLanguage', 'removed', ...french);
    assert.equal(removedLocale.settings.preference, null);
    assert.equal(removedLocale.settings.language, 'fr');
  } finally {
    if (compiled) {
      run('--reset');
    }
    rmSync(directory, { recursive: true });
  }
});
