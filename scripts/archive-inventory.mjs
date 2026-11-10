// Print what an archived app declares: privacy manifests, required-reason APIs,
// permission strings and signed entitlements. This records declarations; it
// does not decide compliance or App Privacy answers (#1958).
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { argv, exit, stderr, stdout } from 'node:process';

import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';

// Absent manifest keys decode as their empty values.
const defaulted = (schema, value) =>
  schema.pipe(Schema.withDecodingDefaultKey(Effect.succeed(value)));
const Strings = defaulted(Schema.Array(Schema.String), []);
const Flag = defaulted(Schema.Boolean, false);
const Info = Schema.Record(Schema.String, Schema.Unknown);
const Build = Schema.Struct({
  CFBundleIdentifier: Schema.String,
  CFBundleShortVersionString: Schema.String,
  CFBundleVersion: Schema.String,
  UnwiredCommit: Schema.optional(Schema.String),
});
const Manifest = Schema.Struct({
  NSPrivacyTracking: Flag,
  NSPrivacyTrackingDomains: Strings,
  NSPrivacyCollectedDataTypes: defaulted(
    Schema.Array(
      Schema.Struct({
        NSPrivacyCollectedDataType: Schema.String,
        NSPrivacyCollectedDataTypeLinked: Flag,
        NSPrivacyCollectedDataTypeTracking: Flag,
        NSPrivacyCollectedDataTypePurposes: Strings,
      }),
    ),
    [],
  ),
  NSPrivacyAccessedAPITypes: defaulted(
    Schema.Array(
      Schema.Struct({
        NSPrivacyAccessedAPIType: Schema.String,
        NSPrivacyAccessedAPITypeReasons: Strings,
      }),
    ),
    [],
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
    return Schema.decodeSync(Schema.fromJsonString(schema))(result.stdout);
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

if (!argv.at(2) || !existsSync(argv.at(2))) {
  fail('usage: archive-inventory.mjs <path.xcarchive|path.app>');
}
const input = path.resolve(argv.at(2));
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

// The walk follows the links in versioned Mac frameworks, so each file is
// listed once under its real path. A dangling link keeps its own path, so a
// dangling manifest fails the read.
const realApp = realpathSync(app);
const canonical = (entry) => {
  try {
    return path.relative(realApp, realpathSync(path.join(app, entry)));
  } catch {
    return entry;
  }
};
const entries = [
  ...new Set(readdirSync(app, { recursive: true }).map(canonical)),
].toSorted();
const manifests = entries
  .filter((entry) => path.basename(entry) === 'PrivacyInfo.xcprivacy')
  .map((entry) => {
    const manifest = plist(Manifest, path.join(app, entry));
    return {
      path: entry,
      tracking: manifest.NSPrivacyTracking,
      trackingDomains: manifest.NSPrivacyTrackingDomains,
      collectedDataTypes: manifest.NSPrivacyCollectedDataTypes.map((type) => ({
        type: type.NSPrivacyCollectedDataType,
        linked: type.NSPrivacyCollectedDataTypeLinked,
        tracking: type.NSPrivacyCollectedDataTypeTracking,
        purposes: type.NSPrivacyCollectedDataTypePurposes,
      })),
      requiredReasonApis: manifest.NSPrivacyAccessedAPITypes.map((api) => ({
        category: api.NSPrivacyAccessedAPIType,
        reasons: api.NSPrivacyAccessedAPITypeReasons,
      })),
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
const embedded = entries.filter((entry) =>
  /\.(?:framework|dylib|appex|xpc|app)$/u.test(entry),
);
// A manifest belongs to the innermost embedded bundle that contains it.
const owner = (manifest) =>
  embedded.findLast((entry) => manifest.startsWith(`${entry}/`));
const code = ['.', ...embedded].map((entry) => ({
  path: entry,
  privacyManifest: manifests.some((manifest) =>
    entry === '.'
      ? manifest.path === appManifest
      : owner(manifest.path) === entry,
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
