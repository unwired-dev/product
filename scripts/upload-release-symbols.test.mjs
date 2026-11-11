import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  cliVersionMatches,
  credentialFailure,
  euHost,
  planUploads,
  redact,
  uploadEnvironment,
  uploadSucceeded,
  versionEnvironment,
} from './upload-release-symbols.mjs';

const root = path.resolve(import.meta.dirname, '..');
const script = path.join(root, 'scripts/upload-release-symbols.mjs');
const key = 'phx_synthetic_upload_key';

function manifest(output) {
  const release = [
    '--release-name',
    'dev.unwired.mail',
    '--release-version',
    '0.1.0',
    '--build',
    '202611111200',
  ];
  return {
    appNamespace: 'dev.unwired.mail',
    appVersion: '0.1.0',
    build: '202611111200',
    uploadCommands: [
      [
        'posthog-cli',
        '--host',
        euHost,
        'hermes',
        'upload',
        '--directory',
        path.join(output, 'hermes'),
        ...release,
        '--release-mode',
        'symbol-set',
      ],
      [
        'posthog-cli',
        '--host',
        euHost,
        'dsym',
        'upload',
        '--directory',
        path.join(output, 'native'),
        ...release,
      ],
    ],
  };
}

test('symbol upload fails closed without a key, project id, or EU host', () => {
  assert.match(
    credentialFailure({
      POSTHOG_CLI_API_KEY: '',
      POSTHOG_CLI_PROJECT_ID: '344845',
      POSTHOG_CLI_HOST: euHost,
    }),
    /POSTHOG_CLI_API_KEY/u,
  );
  assert.match(
    credentialFailure({
      POSTHOG_CLI_API_KEY: 'phx_not a key',
      POSTHOG_CLI_PROJECT_ID: '344845',
      POSTHOG_CLI_HOST: euHost,
    }),
    /POSTHOG_CLI_API_KEY/u,
  );
  assert.match(
    credentialFailure({
      POSTHOG_CLI_API_KEY: key,
      POSTHOG_CLI_PROJECT_ID: '',
      POSTHOG_CLI_HOST: euHost,
    }),
    /POSTHOG_CLI_PROJECT_ID/u,
  );
  assert.match(
    credentialFailure({
      POSTHOG_CLI_API_KEY: key,
      POSTHOG_CLI_PROJECT_ID: '344845',
      POSTHOG_CLI_HOST: 'https://us.posthog.com',
    }),
    /eu\.posthog\.com/u,
  );
  assert.equal(
    credentialFailure({
      POSTHOG_CLI_API_KEY: key,
      POSTHOG_CLI_PROJECT_ID: '344845',
      POSTHOG_CLI_HOST: euHost,
    }),
    null,
  );
  const directory = mkdtempSync(path.join(tmpdir(), 'symbol-evidence-'));
  mkdirSync(path.join(root, 'artifacts/testflight'), { recursive: true });
  const repoEvidence = mkdtempSync(
    path.join(root, 'artifacts/testflight/symbol-evidence-'),
  );
  try {
    writeFileSync(path.join(repoEvidence, 'status.txt'), 'Uploaded: ios\n');
    const pointer = path.join(directory, 'pointer');
    writeFileSync(pointer, `${repoEvidence}\n`);
    const result = spawnSync(
      process.execPath,
      [
        script,
        '--platform',
        'ios',
        '--evidence-path',
        pointer,
        '--cli',
        '/tmp/posthog-cli',
      ],
      {
        cwd: root,
        encoding: 'utf8',
        env: {
          PATH: process.env.PATH,
          ARCHIVE_STEP_OUTCOME: 'success',
          POSTHOG_CLI_API_KEY: key,
          POSTHOG_CLI_PROJECT_ID: '344845',
          POSTHOG_CLI_HOST: 'https://us.i.posthog.com',
        },
      },
    );
    assert.equal(result.status, 1);
    assert.equal(result.stdout.includes(key), false);
    assert.equal(result.stderr.includes(key), false);
    assert.match(result.stderr, /eu\.posthog\.com/u);
    const skipped = spawnSync(
      process.execPath,
      [
        script,
        '--platform',
        'ios',
        '--evidence-path',
        path.join(directory, 'absent'),
        '--cli',
        '/tmp/posthog-cli',
      ],
      {
        cwd: root,
        encoding: 'utf8',
        env: {
          PATH: process.env.PATH,
          ARCHIVE_STEP_OUTCOME: 'failure',
          POSTHOG_CLI_API_KEY: key,
          POSTHOG_CLI_PROJECT_ID: '344845',
          POSTHOG_CLI_HOST: 'https://us.i.posthog.com',
        },
      },
    );
    assert.equal(skipped.status, 0, skipped.stderr);
    assert.match(skipped.stdout, /not attempted/u);
    assert.equal(skipped.stdout.includes(key), false);
    assert.equal(skipped.stderr.includes(key), false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
    rmSync(repoEvidence, { recursive: true, force: true });
  }
});

test('symbol upload keeps the manifest commands and drops compile-time telemetry', () => {
  const output = mkdtempSync(path.join(tmpdir(), 'symbol-plan-'));
  try {
    const planned = planUploads(manifest(output), output);
    assert.equal(
      planned[0][planned[0].indexOf('--release-mode') + 1],
      'symbol-set',
    );
    assert.equal(
      planned.some((command) => command.includes('--force')),
      false,
    );
    const forced = manifest(output);
    forced.uploadCommands[0].push('--force', 'true');
    assert.throws(() => planUploads(forced, output), /refused/u);
    const eventMode = manifest(output);
    eventMode.uploadCommands[0][
      eventMode.uploadCommands[0].indexOf('symbol-set')
    ] = 'event';
    assert.throws(() => planUploads(eventMode, output), /symbol-set/u);
    const outside = manifest(output);
    outside.uploadCommands[1][
      outside.uploadCommands[1].indexOf('--directory') + 1
    ] = tmpdir();
    assert.throws(() => planUploads(outside, output), /outside/u);
  } finally {
    rmSync(output, { recursive: true, force: true });
  }
  const env = uploadEnvironment({
    PATH: '/usr/bin',
    POSTHOG_CLI_API_KEY: key,
    POSTHOG_CLI_PROJECT_ID: '344845',
    POSTHOG_CLI_HOST: 'https://us.posthog.com',
    POSTHOG_API_TOKEN: 'compile-time',
    POSTHOG_RELEASE_MODE: 'event',
    POSTHOG_CLI_DRY_RUN: '1',
  });
  assert.equal(env.POSTHOG_CLI_API_KEY, key);
  assert.equal(env.POSTHOG_CLI_HOST, euHost);
  assert.equal('POSTHOG_API_TOKEN' in env, false);
  assert.equal('POSTHOG_RELEASE_MODE' in env, false);
  assert.equal('POSTHOG_CLI_DRY_RUN' in env, false);
  const versionEnv = versionEnvironment(env);
  assert.equal('POSTHOG_CLI_API_KEY' in versionEnv, false);
  assert.equal(redact(`token ${key} leaked`, key).includes(key), false);
  assert.equal(uploadSucceeded('dsym', 0, 'No dSYM bundles found\n'), false);
  assert.equal(uploadSucceeded('dsym', 0, 'dSYM upload complete\n'), true);
  assert.equal(uploadSucceeded('hermes', 0, 'Found 1 maps to upload\n'), true);
  assert.equal(uploadSucceeded('hermes', 1, 'nothing was uploaded\n'), false);
  assert.equal(cliVersionMatches('posthog-cli 0.18.10\n'), true);
  assert.equal(cliVersionMatches('posthog-cli 0.18.100\n'), false);
});

test('TestFlight keeps the symbol key out of the archive and the CLI build', () => {
  const workflow = readFileSync(
    path.join(root, '.github/workflows/testflight.yml'),
    'utf8',
  );
  const release = readFileSync(
    path.join(root, '.github/workflows/release.yml'),
    'utf8',
  );
  const build = readFileSync(
    path.join(root, 'scripts/build-posthog-cli.zsh'),
    'utf8',
  );
  const revision = /revision=(?<revision>[0-9a-f]{40})/u.exec(build)?.groups
    ?.revision;
  assert.equal(revision, 'e519ba6304903b31e5e3d74c6d1a5fe9a96c745e');
  assert.match(build, /env -u POSTHOG_API_TOKEN -u POSTHOG_CLI_API_KEY/u);
  assert.match(build, /cargo build --release --locked/u);
  assert.match(workflow, new RegExp(revision, 'u'));
  assert.doesNotMatch(workflow, /UNWIRED_NATIVE_ERROR_REPORTING_QUALIFIED/u);
  assert.doesNotMatch(workflow, /--force/u);
  const [, cliJobAndUpload] = workflow.split('\n  posthog-cli:\n');
  const [cliJob] = cliJobAndUpload.split('\n  upload:\n');
  assert.doesNotMatch(cliJob, /POSTHOG_CLI_API_KEY|secrets\./u);
  const [, uploadJob] = workflow.split('\n  upload:\n');
  const [, symbol] = uploadJob.split(
    '      - name: Upload Hermes source maps and dSYMs\n',
  );
  assert.ok(symbol, 'Missing Hermes and dSYM upload step');
  assert.doesNotMatch(
    uploadJob.split('Upload Hermes source maps and dSYMs')[0],
    /POSTHOG_CLI_API_KEY/u,
  );
  assert.match(
    symbol,
    /POSTHOG_CLI_API_KEY: \$\{\{ secrets\.POSTHOG_CLI_API_KEY \}\}/u,
  );
  assert.match(
    symbol,
    /POSTHOG_CLI_PROJECT_ID: \$\{\{ vars\.POSTHOG_CLI_PROJECT_ID \}\}/u,
  );
  assert.match(symbol, /POSTHOG_CLI_HOST: \$\{\{ vars\.POSTHOG_CLI_HOST \}\}/u);
  assert.match(
    symbol,
    /ARCHIVE_STEP_OUTCOME: \$\{\{ steps\.archive\.outcome \}\}/u,
  );
  assert.match(symbol, /if: \$\{\{ !cancelled\(\) \}\}/u);
  assert.match(uploadJob, /\["ios","macos"\]/u);
  assert.match(release, /POSTHOG_CLI_\*/u);
  assert.doesNotMatch(
    readFileSync(path.join(root, 'scripts/testflight.zsh'), 'utf8'),
    /POSTHOG/u,
  );
});
