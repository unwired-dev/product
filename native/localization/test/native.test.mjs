/* oxlint-disable node/no-sync -- Serial native process launches verify preferences after process exit. */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

import { createMessageDateFormat } from '../../../packages/localization/src/message-date-format.ts';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const parseJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);

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
    parseJson(execFileSync(binary, args, { encoding: 'utf8' }));
  let compiled = false;
  try {
    execFileSync('xcrun', [
      'clang',
      '-fobjc-arc',
      '-DNS_BLOCK_ASSERTIONS',
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
    assert.equal(new Intl.Locale(regional.settings.locale).baseName, 'en-CZ');
    assert.doesNotThrow(() =>
      new Intl.DateTimeFormat(regional.settings.locale).format(new Date(0)),
    );
    for (const [identifier, calendar, numberingSystem] of [
      ['en_US@calendar=buddhist;numbers=thai', 'buddhist', 'thai'],
      ['en_US@calendar=gregorian;numbers=arab', 'gregory', 'arab'],
      ['en-US-u-ca-japanese-nu-fullwide', 'japanese', 'fullwide'],
      ['en_US@calendar=ethiopic-amete-alem', 'ethioaa', 'latn'],
      ['en_US@rg=czzzzz;calendar=buddhist;numbers=thai', 'buddhist', 'thai'],
    ]) {
      const { settings } = run('-AppleLocale', identifier);
      const formatter = new Intl.DateTimeFormat(settings.locale, {
        year: 'numeric',
        timeZone: 'UTC',
      });
      assert.equal(formatter.resolvedOptions().calendar, calendar);
      assert.equal(
        formatter.resolvedOptions().numberingSystem,
        numberingSystem,
      );
      assert.equal(
        formatter.format(new Date(0)),
        new Intl.DateTimeFormat('en-US', {
          calendar,
          numberingSystem,
          year: 'numeric',
          timeZone: 'UTC',
        }).format(new Date(0)),
      );
    }
    for (const [identifier, force24, force12, hourCycle, hours] of [
      ['en_US', 'YES', 'NO', 'h23', ['00', '13']],
      ['en_GB', 'NO', 'YES', 'h12', ['12', '1']],
    ]) {
      const preferences = [
        '-AppleLocale',
        identifier,
        '-AppleICUForce24HourTime',
        force24,
        '-AppleICUForce12HourTime',
        force12,
      ];
      const { settings } = run(...preferences);
      const formatter = createMessageDateFormat(settings.locale, true);
      assert.equal(formatter.resolvedOptions().hourCycle, hourCycle);
      assert.deepEqual(
        [new Date(0), new Date(13 * 60 * 60 * 1000)].map(
          (date) =>
            formatter.formatToParts(date).find((part) => part.type === 'hour')
              .value,
        ),
        hours,
      );
      const override = run('-interfaceLanguage', 'en', ...preferences);
      assert.equal(override.settings.locale, 'en');
    }
    const system = run(...french);
    assert.equal(system.settings.language, 'fr');
    assert.equal(new Intl.Locale(system.settings.locale).baseName, 'fr-CA');
    assert.equal(system.showInbox, 'Afficher la boîte de réception');
    assert.equal(system.hide, 'Hide Unwired Mail');
    const switches = run('--switch-languages', ...french);
    assert.deepEqual(
      switches.map((value) => value.showInbox),
      [
        'Afficher la boîte de réception',
        'Show Inbox',
        'Afficher la boîte de réception',
      ],
    );
    assert.deepEqual(
      switches.map((value) => value.hide),
      ['Hide Unwired Mail', 'Hide Unwired Mail', 'Hide Unwired Mail'],
    );
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
    // A listed language whose catalog is missing falls back to English instead of crashing.
    writeFileSync(
      path.join(resources, 'languages.json'),
      JSON.stringify([
        { code: 'en', name: 'English' },
        { code: 'de', name: 'Deutsch' },
      ]),
    );
    const uncatalogued = run('-AppleLanguages', '(de-DE)');
    assert.equal(uncatalogued.settings.language, 'de');
    assert.equal(uncatalogued.showInbox, 'Show Inbox');
    assert.equal(uncatalogued.hide, 'Hide Unwired Mail');
    // Invalid JSON exercises the parser failure and cached fallback in Release too.
    writeFileSync(path.join(resources, 'de.json'), '{invalid json');
    const invalidCatalog = run('-AppleLanguages', '(de-DE)');
    assert.equal(invalidCatalog.settings.language, 'de');
    assert.equal(invalidCatalog.showInbox, 'Show Inbox');
    assert.equal(invalidCatalog.hide, 'Hide Unwired Mail');
  } finally {
    if (compiled) {
      run('--reset');
    }
    rmSync(directory, { recursive: true });
  }
});
