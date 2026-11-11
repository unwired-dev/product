// Print what an archive's inventories leave unresolved and the owner or legal
// submissions it still needs. The record never states that an archive is
// compliant: with no findings, the submissions remain (#1971).
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { argv, exit, stderr, stdout } from 'node:process';

import * as Schema from 'effect/Schema';

const Strings = Schema.Array(Schema.String);
const Inventory = Schema.Struct({
  build: Schema.Struct({
    bundleId: Schema.String,
    version: Schema.String,
    buildNumber: Schema.String,
    commit: Schema.NullOr(Schema.String),
    platform: Schema.String,
  }),
  encryption: Schema.Struct({
    usesNonExemptEncryption: Schema.NullOr(Schema.Boolean),
  }),
  privacyManifests: Schema.Array(
    Schema.Struct({
      path: Schema.String,
      tracking: Schema.Boolean,
      trackingDomains: Strings,
      collectedDataTypes: Schema.Array(
        Schema.Struct({ type: Schema.String, tracking: Schema.Boolean }),
      ),
    }),
  ),
  code: Schema.Array(
    Schema.Struct({
      path: Schema.String,
      cryptography: Schema.Struct({
        libraries: Strings,
        imports: Strings,
        bundled: Strings,
      }),
    }),
  ),
  withoutPrivacyManifest: Strings,
});
const Licences = Schema.Struct({
  undeclared: Strings,
  withoutLicenceFile: Strings,
});
const NativeLicences = Schema.Struct({
  pods: Schema.Array(
    Schema.Struct({ name: Schema.String, version: Schema.String }),
  ),
  undeclared: Strings,
  withoutLicenceText: Strings,
});

const fail = (message) => {
  stderr.write(`archive-findings: ${message}\n`);
  exit(1);
};

const read = (schema, file) => {
  try {
    return Schema.decodeSync(Schema.fromJsonString(schema))(
      readFileSync(file, 'utf8'),
    );
  } catch (error) {
    return fail(`unreadable ${file}: ${error.message}`);
  }
};

const [inventoryFile, licencesFile, nativeLicencesFile] = argv.slice(2);
if (!nativeLicencesFile) {
  fail(
    'usage: archive-findings.mjs <inventory.json> <licences.json> <native-licences.json>',
  );
}
const inventory = read(Inventory, inventoryFile);
const licences = read(Licences, licencesFile);
const native = read(NativeLicences, nativeLicencesFile);

const each = (kind, subjects) => subjects.map((subject) => ({ kind, subject }));
// Only pods declare licences; the other native ids are Swift packages.
const pods = new Set(
  native.pods.map(({ name, version }) => `${name}@${version}`),
);
const nativeKind = (id) => `${pods.has(id) ? 'pod' : 'swift'} ${id}`;
const findings = [
  ...each('undeclared-licence', [
    ...licences.undeclared.map((id) => `npm ${id}`),
    ...native.undeclared.map(nativeKind),
  ]),
  ...each('missing-licence-text', [
    ...licences.withoutLicenceFile.map((id) => `npm ${id}`),
    ...native.withoutLicenceText.map(nativeKind),
  ]),
  ...each(
    'missing-app-privacy-manifest',
    inventory.withoutPrivacyManifest.filter((code) => code === '.'),
  ),
  ...each(
    'tracking-declared',
    inventory.privacyManifests
      .filter((manifest) =>
        [
          manifest.tracking,
          manifest.trackingDomains.length > 0,
          ...manifest.collectedDataTypes.map((type) => type.tracking),
        ].includes(true),
      )
      .map((manifest) => manifest.path),
  ),
  ...each(
    'missing-encryption-declaration',
    inventory.encryption.usesNonExemptEncryption === null
      ? ['ITSAppUsesNonExemptEncryption']
      : [],
  ),
];

// Each submission names the evidence it rests on. An empty cryptography list
// does not show that the archive ships none, so the determination stays.
const ownerSubmissions = [
  {
    kind: 'export-compliance',
    evidence: inventory.code
      .filter(({ cryptography }) =>
        Object.values(cryptography).some((names) => names.length > 0),
      )
      .map((code) => code.path),
  },
  {
    kind: 'app-privacy-answers',
    evidence: [
      ...new Set(
        inventory.privacyManifests.flatMap((manifest) =>
          manifest.collectedDataTypes.map((type) => type.type),
        ),
      ),
    ].toSorted(),
  },
  {
    kind: 'licence-notices',
    evidence: [licencesFile, nativeLicencesFile].map((file) =>
      path.basename(file),
    ),
  },
];

stdout.write(
  `${JSON.stringify({ build: inventory.build, findings, ownerSubmissions }, null, 2)}\n`,
);
