// Print what an archived app declares: privacy manifests, required-reason APIs,
// permission strings and signed entitlements. This records declarations; it
// does not decide compliance or App Privacy answers (#1958).
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { argv, exit, stderr, stdout } from 'node:process';

import * as Schema from 'effect/Schema';

const Strings = Schema.optional(Schema.Array(Schema.String));
const Info = Schema.Record(Schema.String, Schema.Unknown);
const Build = Schema.Struct({
  CFBundleIdentifier: Schema.String,
  CFBundleShortVersionString: Schema.String,
  CFBundleVersion: Schema.String,
  UnwiredCommit: Schema.optional(Schema.String),
});
const Manifest = Schema.Struct({
  NSPrivacyTracking: Schema.optional(Schema.Boolean),
  NSPrivacyTrackingDomains: Strings,
  NSPrivacyCollectedDataTypes: Schema.optional(
    Schema.Array(
      Schema.Struct({
        NSPrivacyCollectedDataType: Schema.String,
        NSPrivacyCollectedDataTypeLinked: Schema.optional(Schema.Boolean),
        NSPrivacyCollectedDataTypeTracking: Schema.optional(Schema.Boolean),
        NSPrivacyCollectedDataTypePurposes: Strings,
      }),
    ),
  ),
  NSPrivacyAccessedAPITypes: Schema.optional(
    Schema.Array(
      Schema.Struct({
        NSPrivacyAccessedAPIType: Schema.String,
        NSPrivacyAccessedAPITypeReasons: Strings,
      }),
    ),
  ),
});

const fail = (message) => {
  stderr.write(`archive-inventory: ${message}\n`);
  exit(1);
};

const run = (command, args, input) =>
  spawnSync(command, args, {
    encoding: 'utf8',
    input,
    maxBuffer: 64 * 1024 * 1024,
  });

// Reads a property list file, or stdin text when `file` is '-'.
const plist = (schema, file, text) => {
  const result = run(
    'plutil',
    ['-convert', 'json', '-o', '-', '--', file],
    text,
  );
  try {
    if (result.status !== 0) {
      throw new Error(`${result.stderr}${result.stdout}`.trim());
    }
    return Schema.decodeUnknownSync(Schema.fromJsonString(schema))(
      result.stdout,
    );
  } catch (error) {
    return fail(
      `unreadable property list ${text === undefined ? file : 'from codesign'}: ${error.message}`,
    );
  }
};

const sortedKeys = (record) =>
  Object.fromEntries(
    Object.entries(record).toSorted(([a], [b]) => a.localeCompare(b)),
  );

const entitlements = (bundle) => {
  const result = run('codesign', [
    '-d',
    '--entitlements',
    '-',
    '--xml',
    bundle,
  ]);
  if (result.status !== 0) {
    if (result.stderr.includes('not signed at all')) {
      return 'unsigned';
    }
    return fail(`codesign failed for ${bundle}: ${result.stderr.trim()}`);
  }
  return result.stdout.trim() === ''
    ? {}
    : sortedKeys(plist(Info, '-', result.stdout));
};

const input = argv.at(2);
if (!input || !existsSync(input)) {
  fail('usage: archive-inventory.mjs <path.xcarchive|path.app>');
}
let app = input;
if (input.endsWith('.xcarchive')) {
  const applications = path.join(input, 'Products/Applications');
  const apps = existsSync(applications)
    ? readdirSync(applications).filter((name) => name.endsWith('.app'))
    : [];
  if (apps.length !== 1) {
    fail(`expected one app in ${applications}`);
  }
  [app] = apps.map((name) => path.join(applications, name));
}
const macos = existsSync(path.join(app, 'Contents/Info.plist'));
const contents = macos ? 'Contents/' : '';
const infoFile = path.join(app, `${contents}Info.plist`);
const info = plist(Info, infoFile);
const build = plist(Build, infoFile);

const entries = readdirSync(app, { recursive: true, withFileTypes: true })
  .filter((entry) => !entry.isSymbolicLink())
  .map((entry) => path.relative(app, path.join(entry.parentPath, entry.name)))
  .toSorted();
const manifests = entries
  .filter((entry) => path.basename(entry) === 'PrivacyInfo.xcprivacy')
  .map((entry) => {
    const manifest = plist(Manifest, path.join(app, entry));
    return {
      path: entry,
      tracking: manifest.NSPrivacyTracking ?? false,
      trackingDomains: manifest.NSPrivacyTrackingDomains ?? [],
      collectedDataTypes: (manifest.NSPrivacyCollectedDataTypes ?? []).map(
        (type) => ({
          type: type.NSPrivacyCollectedDataType,
          linked: type.NSPrivacyCollectedDataTypeLinked ?? false,
          tracking: type.NSPrivacyCollectedDataTypeTracking ?? false,
          purposes: type.NSPrivacyCollectedDataTypePurposes ?? [],
        }),
      ),
      requiredReasonApis: (manifest.NSPrivacyAccessedAPITypes ?? []).map(
        (api) => ({
          category: api.NSPrivacyAccessedAPIType,
          reasons: api.NSPrivacyAccessedAPITypeReasons ?? [],
        }),
      ),
    };
  });

const requiredReasonApis = {};
for (const { category, reasons } of manifests.flatMap(
  (manifest) => manifest.requiredReasonApis,
)) {
  requiredReasonApis[category] = [
    ...new Set([...(requiredReasonApis[category] ?? []), ...reasons]),
  ].toSorted();
}

// Embedded code is every nested framework, dylib, extension and helper, plus the app itself.
const appManifest = `${contents}${macos ? 'Resources/' : ''}PrivacyInfo.xcprivacy`;
const code = [
  '.',
  ...entries.filter((entry) =>
    /\.(?:framework|dylib|appex|xpc|app)$/u.test(entry),
  ),
].map((entry) => ({
  path: entry,
  privacyManifest: manifests.some((manifest) =>
    entry === '.'
      ? manifest.path === appManifest
      : manifest.path.startsWith(`${entry}/`),
  ),
  entitlements: entitlements(path.join(app, entry)),
}));

stdout.write(
  `${JSON.stringify(
    {
      build: {
        bundleId: build.CFBundleIdentifier,
        version: build.CFBundleShortVersionString,
        buildNumber: build.CFBundleVersion,
        commit: build.UnwiredCommit ?? null,
        platform: macos ? 'macos' : 'ios',
      },
      privacyManifests: manifests,
      requiredReasonApis: sortedKeys(requiredReasonApis),
      permissions: sortedKeys(
        Object.fromEntries(
          Object.entries(info).filter(([key]) =>
            key.endsWith('UsageDescription'),
          ),
        ),
      ),
      code,
      withoutPrivacyManifest: code
        .filter((item) => !item.privacyManifest)
        .map((item) => item.path),
    },
    null,
    2,
  )}\n`,
);
