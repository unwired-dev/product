import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';

import * as Schema from 'effect/Schema';

const decodeJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);

const root = path.join(import.meta.dirname, '..');
const script = path.join(root, 'scripts/archive-findings.mjs');

const build = {
  bundleId: 'dev.unwired.mail',
  version: '0.1.0',
  buildNumber: '202611110100',
  commit: 'abc123',
  platform: 'ios',
};
const none = { libraries: [], imports: [], bundled: [] };
const gmailScope = 'https://www.googleapis.com/auth/gmail.modify';
const googleAuthorization = {
  status: 'owner-verified',
  verified: '2026-10-28',
  scopes: [
    gmailScope,
    'https://www.googleapis.com/auth/userinfo.email',
    'https://www.googleapis.com/auth/userinfo.profile',
    'openid',
  ],
};
const manifest = (manifestPath, overrides = {}) => ({
  path: manifestPath,
  tracking: false,
  trackingDomains: [],
  collectedDataTypes: [],
  requiredReasonApis: [],
  ...overrides,
});
// The app and two frameworks: one ships cryptography, one has no manifest.
// They name fewer Google scopes than the verified authorization.
const inventory = (overrides = {}) => ({
  build,
  encryption: { usesNonExemptEncryption: false, exportComplianceCode: null },
  privacyManifests: [
    manifest('PrivacyInfo.xcprivacy', {
      collectedDataTypes: [
        {
          type: 'NSPrivacyCollectedDataTypeUserID',
          linked: true,
          tracking: false,
        },
        {
          type: 'NSPrivacyCollectedDataTypeDeviceID',
          linked: true,
          tracking: false,
        },
      ],
    }),
    manifest('Frameworks/Crypto.framework/PrivacyInfo.xcprivacy', {
      collectedDataTypes: [
        {
          type: 'NSPrivacyCollectedDataTypeUserID',
          linked: true,
          tracking: false,
        },
      ],
    }),
  ],
  requiredReasonApis: {},
  permissions: {},
  code: [
    { path: '.', cryptography: none, googleScopes: [gmailScope] },
    {
      path: 'Frameworks/Crypto.framework',
      cryptography: { ...none, imports: ['_CCCrypt'] },
      googleScopes: [],
    },
    {
      path: 'Frameworks/Plain.framework',
      cryptography: none,
      googleScopes: ['https://www.googleapis.com/auth/userinfo.email'],
    },
  ],
  withoutPrivacyManifest: ['Frameworks/Plain.framework'],
  ...overrides,
});

function run({ archive = inventory(), npm = {}, native = {} } = {}) {
  mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
  const directory = mkdtempSync(
    path.join(root, 'scratchpad/archive-findings-'),
  );
  const files = [
    ['ios-inventory.json', archive],
    [
      'ios-licences.json',
      { packages: [], undeclared: [], withoutLicenceFile: [], ...npm },
    ],
    [
      'ios-native-licences.json',
      {
        pods: [],
        swiftPackages: [],
        undeclared: [],
        withoutLicenceText: [],
        ...native,
      },
    ],
  ].map(([name, value]) => {
    const file = path.join(directory, name);
    writeFileSync(
      file,
      typeof value === 'string' ? value : JSON.stringify(value),
    );
    return file;
  });
  try {
    return spawnSync(process.execPath, [script, ...files], {
      encoding: 'utf8',
    });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

const findings = (options) => {
  const result = run(options);
  assert.equal(result.status, 0, result.stderr);
  return decodeJson(result.stdout);
};

test('an archive without findings still lists every owner submission and claims no compliance', () => {
  assert.deepEqual(findings(), {
    build,
    googleAuthorization,
    findings: [],
    ownerSubmissions: [
      { kind: 'export-compliance', evidence: ['Frameworks/Crypto.framework'] },
      {
        kind: 'app-privacy-answers',
        evidence: [
          'NSPrivacyCollectedDataTypeDeviceID',
          'NSPrivacyCollectedDataTypeUserID',
        ],
      },
      {
        kind: 'licence-notices',
        evidence: ['ios-licences.json', 'ios-native-licences.json'],
      },
    ],
  });
});

test('inventory gaps become findings', () => {
  const archive = inventory({
    encryption: { usesNonExemptEncryption: null, exportComplianceCode: null },
    privacyManifests: [
      manifest('Frameworks/Ads.framework/PrivacyInfo.xcprivacy', {
        tracking: true,
      }),
      manifest('Frameworks/Beacon.framework/PrivacyInfo.xcprivacy', {
        trackingDomains: ['beacon.example'],
      }),
      manifest('Frameworks/Metrics.framework/PrivacyInfo.xcprivacy', {
        collectedDataTypes: [
          {
            type: 'NSPrivacyCollectedDataTypeDeviceID',
            linked: false,
            tracking: true,
          },
        ],
      }),
    ],
    withoutPrivacyManifest: ['.', 'Frameworks/Plain.framework'],
  });
  assert.deepEqual(
    findings({
      archive,
      npm: { undeclared: ['inner@0.1.0'], withoutLicenceFile: ['inner@0.1.0'] },
      native: {
        pods: [{ name: 'Pod', version: '1.0.0' }],
        undeclared: ['Pod@1.0.0'],
        withoutLicenceText: ['Pod@1.0.0', 'swift-log@1.6.0'],
      },
    }).findings,
    [
      { kind: 'undeclared-licence', subject: 'npm inner@0.1.0' },
      { kind: 'undeclared-licence', subject: 'pod Pod@1.0.0' },
      { kind: 'missing-licence-text', subject: 'npm inner@0.1.0' },
      { kind: 'missing-licence-text', subject: 'pod Pod@1.0.0' },
      { kind: 'missing-licence-text', subject: 'swift swift-log@1.6.0' },
      { kind: 'missing-app-privacy-manifest', subject: '.' },
      {
        kind: 'tracking-declared',
        subject: 'Frameworks/Ads.framework/PrivacyInfo.xcprivacy',
      },
      {
        kind: 'tracking-declared',
        subject: 'Frameworks/Beacon.framework/PrivacyInfo.xcprivacy',
      },
      {
        kind: 'tracking-declared',
        subject: 'Frameworks/Metrics.framework/PrivacyInfo.xcprivacy',
      },
      {
        kind: 'missing-encryption-declaration',
        subject: 'ITSAppUsesNonExemptEncryption',
      },
    ],
  );
});

test('a Google scope outside the verified authorization needs revalidation', () => {
  const added = [
    'https://mail.google.com/',
    'https://www.googleapis.com/auth/calendar',
  ];
  const archive = inventory();
  archive.code[2].googleScopes = [added[1], gmailScope];
  archive.code[1].googleScopes = [added[0], added[1]];
  const record = findings({ archive });
  assert.deepEqual(record.googleAuthorization, googleAuthorization);
  assert.deepEqual(
    record.findings,
    added.map((subject) => ({ kind: 'unverified-google-scope', subject })),
  );
  assert.deepEqual(record.ownerSubmissions.at(-1), {
    kind: 'google-revalidation',
    evidence: added,
  });
});

test('an unreadable inventory fails', () => {
  const result = run({ archive: '{"build": {}}' });
  assert.equal(result.status, 1);
  assert.match(
    result.stderr,
    /^archive-findings: unreadable .*ios-inventory\.json/u,
  );
  assert.equal(result.stdout, '');
});
