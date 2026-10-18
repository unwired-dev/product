import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';

import * as Schema from 'effect/Schema';

const cliVersion = '0.18.10';
const cliRevision = 'e519ba6304903b31e5e3d74c6d1a5fe9a96c745e';
const decodeJson = Schema.decodeUnknownSync(
  Schema.fromJsonString(Schema.Record(Schema.String, Schema.Unknown)),
);
const validMap = Schema.is(
  Schema.Struct({
    version: Schema.Literal(3),
    sources: Schema.Array(Schema.String).check(Schema.isMinLength(1)),
    mappings: Schema.String.check(Schema.isMinLength(1)),
    x_hermes_function_offsets: Schema.Record(
      Schema.String,
      Schema.Array(Schema.Int),
    ),
  }),
);
const versionPattern = /^[0-9]{1,8}(?:\.[0-9]{1,8}){0,3}$/u;
const buildPattern = /^[0-9]{1,18}$/u;
const uuidPattern = /UUID: (?<uuid>[0-9A-F-]{36}) \((?<arch>[^)]+)\)/giu;

function uuids(file) {
  const result = spawnSync('/usr/bin/xcrun', ['dwarfdump', '--uuid', file], {
    encoding: 'utf8',
  });
  if (result.status !== 0) {
    throw new Error(
      'dwarfdump failed; install Xcode tools and provide the archive binary and its dSYM.',
    );
  }
  const identities = [...result.stdout.matchAll(uuidPattern)]
    .map((match) => `${match.groups.uuid.toUpperCase()}:${match.groups.arch}`)
    .toSorted();
  if (identities.length === 0) {
    throw new Error('Artifact contains no Mach-O UUIDs.');
  }
  return identities;
}

function digest(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function validVersion(value) {
  return value !== undefined && versionPattern.test(value);
}

function validBuild(value) {
  return value !== undefined && buildPattern.test(value);
}

function appRelease(binary) {
  const plist = path.join(path.dirname(path.resolve(binary)), 'Info.plist');
  return ['CFBundleShortVersionString', 'CFBundleVersion'].map((key) => {
    const result = spawnSync(
      '/usr/libexec/PlistBuddy',
      ['-c', `Print :${key}`, plist],
      { encoding: 'utf8' },
    );
    if (result.status !== 0) {
      throw new Error('Archive Info.plist must accompany the executable.');
    }
    return result.stdout.trim();
  });
}

function validateRelease(binary, version, build) {
  const [appVersion, appBuild] = appRelease(binary);
  if (appVersion !== version || appBuild !== build) {
    throw new Error(
      'Release coordinates do not match the archived app Info.plist.',
    );
  }
}

function main() {
  const { values } = parseArgs({
    options: {
      platform: { type: 'string' },
      version: { type: 'string' },
      build: { type: 'string' },
      bundle: { type: 'string' },
      map: { type: 'string' },
      binary: { type: 'string' },
      dsym: { type: 'string' },
      output: { type: 'string' },
      help: { type: 'boolean' },
    },
  });
  if (values.help) {
    process.stdout.write(
      'Prepare release artifacts locally; never uploads or invokes vendor tools.\nnode scripts/reporting-artifacts.mjs --platform ios|macos --version 1.0.0 --build 42 --bundle /archive/main.jsbundle --map /archive/main.jsbundle.map --binary /archive/App.app/App --dsym /archive/App.app.dSYM --output /new/artifact-directory\nUse the final composed Hermes map and bytecode from the same archive.\n',
    );
    return;
  }
  if (
    (values.platform !== 'ios' && values.platform !== 'macos') ||
    !validVersion(values.version) ||
    !validBuild(values.build) ||
    !values.bundle ||
    !values.map ||
    !values.binary ||
    !values.dsym ||
    !values.output
  ) {
    throw new Error(
      'Required release coordinates or artifacts are missing; use --help.',
    );
  }
  const output = path.resolve(values.output);
  if (existsSync(output)) {
    throw new Error(
      'Output already exists; use a new directory so stale symbols cannot be uploaded.',
    );
  }
  const bytecode = readFileSync(values.bundle);
  if (
    bytecode.length < 32 ||
    !bytecode.subarray(0, 8).equals(Buffer.from('c61fbc03c103191f', 'hex'))
  ) {
    throw new Error(
      'Bundle is not Hermes bytecode; plain Metro exports cannot qualify native Hermes stacks.',
    );
  }
  const sourceMapBytes = readFileSync(values.map);
  const sourceMap = decodeJson(sourceMapBytes.toString('utf8'));
  if (
    !validMap(sourceMap) ||
    Object.keys(sourceMap.x_hermes_function_offsets).length === 0
  ) {
    throw new Error(
      'Expected a nonempty composed Hermes map with x_hermes_function_offsets; plain Metro maps are refused.',
    );
  }
  if (!values.dsym.endsWith('.dSYM')) {
    throw new Error('Expected an Apple .dSYM bundle.');
  }
  validateRelease(values.binary, values.version, values.build);
  const nativeIds = uuids(path.resolve(values.binary));
  const symbolIds = uuids(path.resolve(values.dsym));
  if (JSON.stringify(nativeIds) !== JSON.stringify(symbolIds)) {
    throw new Error(
      'dSYM UUID/architecture set does not match the shipped executable.',
    );
  }
  const canonical = `app:///${values.platform}/${values.version}/${values.build}/index.bundle`;
  // The receiver derives this identity from bounded release coordinates, never client filenames.
  const prepared = { ...sourceMap, file: canonical, chunk_id: canonical };
  delete prepared.chunkId;
  delete prepared.debugId;
  delete prepared.release_id;
  const release = [
    '--release-name',
    `unwired-${values.platform}`,
    '--release-version',
    values.version,
    '--build',
    values.build,
  ];
  const hermesDirectory = path.join(output, 'hermes');
  const nativeDirectory = path.join(output, 'native');
  mkdirSync(output, { recursive: true });
  try {
    mkdirSync(hermesDirectory);
    mkdirSync(nativeDirectory);
    writeFileSync(
      path.join(hermesDirectory, 'index.bundle.map'),
      JSON.stringify(prepared),
    );
    cpSync(
      values.dsym,
      path.join(nativeDirectory, path.basename(values.dsym)),
      { recursive: true },
    );
    const manifest = {
      platform: values.platform,
      appVersion: values.version,
      build: values.build,
      canonical,
      chunkId: canonical,
      bytecodeSha256: digest(bytecode),
      composedMapSha256: digest(sourceMapBytes),
      nativeIds,
      cli: {
        version: cliVersion,
        revision: cliRevision,
        requirement:
          'Build from this revision with POSTHOG_API_TOKEN absent; distributed binaries have separate built-in telemetry.',
      },
      uploadCommands: [
        [
          'posthog-cli',
          '--host',
          'https://eu.posthog.com',
          'hermes',
          'upload',
          '--directory',
          hermesDirectory,
          ...release,
          '--release-mode',
          'symbol-set',
        ],
        [
          'posthog-cli',
          '--host',
          'https://eu.posthog.com',
          'dsym',
          'upload',
          '--directory',
          nativeDirectory,
          ...release,
        ],
      ],
      qualification:
        'pending: actual stack resolution and exact bytecode/map pairing must be verified against this archive in issue #1050',
    };
    writeFileSync(
      path.join(output, 'manifest.json'),
      `${JSON.stringify(manifest, null, 2)}\n`,
    );
    process.stdout.write(
      `Prepared ${canonical}; dSYM UUIDs match. Upload and symbolication remain unverified.\n`,
    );
  } catch (error) {
    rmSync(output, { recursive: true, force: true });
    throw error;
  }
}

try {
  main();
} catch (error) {
  process.stderr.write(
    `${error instanceof Error ? error.message : 'Artifact preparation failed.'}\n`,
  );
  process.exitCode = 1;
}
