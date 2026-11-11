// Upload one signed archive's Hermes map and dSYM with the manifest from
// reporting-artifacts.mjs. Credentials stay in this process: preparation and
// the CLI version check run without them, and output is redacted.
import { spawnSync } from 'node:child_process';
import {
  appendFileSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  readdirSync,
  rmSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

import * as Schema from 'effect/Schema';

export const euHost = 'https://eu.posthog.com';
const cliVersion = '0.18.10';
const appNamespace = 'dev.unwired.mail';
const dropped = new Set([
  'POSTHOG_API_TOKEN',
  'POSTHOG_RELEASE_MODE',
  'POSTHOG_CLI_TOKEN',
  'POSTHOG_CLI_ENV_ID',
  'POSTHOG_CLI_DOTENV_FILE',
  'POSTHOG_CLI_DRY_RUN',
]);
const decodeManifest = Schema.decodeUnknownSync(
  Schema.fromJsonString(
    Schema.Struct({
      appNamespace: Schema.String,
      appVersion: Schema.String,
      build: Schema.String,
      uploadCommands: Schema.Array(Schema.Array(Schema.String)),
    }),
  ),
);

function invalidKey(key) {
  if (typeof key !== 'string') {
    return true;
  }
  if (!key.startsWith('phx_')) {
    return true;
  }
  if (key !== key.trim()) {
    return true;
  }
  return /\s/u.test(key);
}

function invalidProject(project) {
  if (typeof project !== 'string') {
    return true;
  }
  return !/^[0-9]{1,12}$/u.test(project);
}

export function credentialFailure(env) {
  if (invalidKey(env.POSTHOG_CLI_API_KEY)) {
    return 'POSTHOG_CLI_API_KEY is required; symbol upload cannot be skipped.';
  }
  if (invalidProject(env.POSTHOG_CLI_PROJECT_ID)) {
    return 'POSTHOG_CLI_PROJECT_ID is required; symbol upload cannot be skipped.';
  }
  if (env.POSTHOG_CLI_HOST !== euHost) {
    return 'POSTHOG_CLI_HOST must be https://eu.posthog.com; symbol upload cannot be skipped.';
  }
  return null;
}

function keyPresent(key) {
  if (typeof key !== 'string') {
    return false;
  }
  return key.length > 0;
}

export function redact(text, key) {
  if (typeof text !== 'string') {
    return '';
  }
  if (!keyPresent(key)) {
    return text;
  }
  return text.split(key).join('[redacted]');
}

export function uploadEnvironment(env) {
  const next = {};
  for (const [name, value] of Object.entries(env)) {
    if (!dropped.has(name)) {
      next[name] = value;
    }
  }
  next.POSTHOG_CLI_HOST = euHost;
  return next;
}

export function versionEnvironment(env) {
  const next = uploadEnvironment(env);
  delete next.POSTHOG_CLI_API_KEY;
  delete next.POSTHOG_CLI_PROJECT_ID;
  return next;
}

export function cliVersionMatches(output) {
  return /(?:^|\s)0\.18\.10(?:\s|$)/u.test(output);
}

function repeated(command, name, index) {
  if (index === -1) {
    return true;
  }
  return index !== command.lastIndexOf(name);
}

function flag(command, name) {
  const index = command.indexOf(name);
  if (repeated(command, name, index)) {
    return undefined;
  }
  const value = command[index + 1];
  if (value === undefined) {
    return undefined;
  }
  if (value.startsWith('-')) {
    return undefined;
  }
  return value;
}

function inside(parent, child) {
  const root = path.resolve(parent);
  const target = path.resolve(child);
  return target.startsWith(`${root}${path.sep}`);
}

function targetsEu(command) {
  if (command[0] !== 'posthog-cli') {
    return false;
  }
  if (command[1] !== '--host') {
    return false;
  }
  return command[2] === euHost;
}

function isUpload(command, kind) {
  return command[3] === kind && command[4] === 'upload';
}

function commandKind(command) {
  if (!targetsEu(command)) {
    throw new Error('Symbol upload must target https://eu.posthog.com.');
  }
  if (isUpload(command, 'hermes')) {
    return 'hermes';
  }
  if (isUpload(command, 'dsym')) {
    return 'dsym';
  }
  throw new Error(
    'Symbol upload only runs the manifest Hermes and dSYM commands.',
  );
}

const refusedCommand =
  'Symbol upload refused a command that is not the manifest Hermes or dSYM upload.';
const expectedCommands =
  'Symbol upload expected the Hermes map command and the dSYM command.';

function allowedFlags(kind) {
  if (kind === 'hermes') {
    return [
      '--directory',
      '--release-name',
      '--release-version',
      '--build',
      '--release-mode',
    ];
  }
  return ['--directory', '--release-name', '--release-version', '--build'];
}

function requireFlag(command, name) {
  const value = flag(command, name);
  if (value === undefined) {
    throw new Error(refusedCommand);
  }
  return value;
}

function validatePairs(command, kind) {
  const allowed = allowedFlags(kind);
  for (let index = 5; index < command.length; index += 2) {
    const name = command[index];
    if (!allowed.includes(name)) {
      throw new Error(refusedCommand);
    }
    requireFlag(command, name);
  }
  if (command.length !== 5 + allowed.length * 2) {
    throw new Error(refusedCommand);
  }
}

function coordinatesMatch(command, manifest) {
  if (requireFlag(command, '--release-version') !== manifest.appVersion) {
    return false;
  }
  return requireFlag(command, '--build') === manifest.build;
}

function validateCoordinates(command, manifest, outputDirectory) {
  if (requireFlag(command, '--release-name') !== appNamespace) {
    throw new Error('Symbol upload refused an unapproved reporting namespace.');
  }
  if (!coordinatesMatch(command, manifest)) {
    throw new Error(
      'Symbol upload release coordinates do not match the manifest.',
    );
  }
  if (!inside(outputDirectory, requireFlag(command, '--directory'))) {
    throw new Error(
      'Symbol upload refused a directory outside the prepared artifacts.',
    );
  }
}

function validateHermesMode(command, kind) {
  if (kind !== 'hermes') {
    return;
  }
  if (requireFlag(command, '--release-mode') !== 'symbol-set') {
    throw new Error(
      'Hermes upload must use symbol-set mode so a conflicting release is not replaced.',
    );
  }
}

function validateCommand(command, context) {
  const kind = commandKind(command);
  if (context.kinds.has(kind)) {
    throw new Error(expectedCommands);
  }
  context.kinds.add(kind);
  validatePairs(command, kind);
  validateCoordinates(command, context.manifest, context.outputDirectory);
  validateHermesMode(command, kind);
}

function manifestShape(manifest) {
  if (manifest.appNamespace !== appNamespace) {
    throw new Error('Symbol upload refused an unapproved reporting namespace.');
  }
  if (manifest.uploadCommands.length !== 2) {
    throw new Error(expectedCommands);
  }
}

function hasBothUploads(kinds) {
  if (!kinds.has('hermes')) {
    return false;
  }
  return kinds.has('dsym');
}

export function planUploads(manifest, outputDirectory) {
  manifestShape(manifest);
  const context = { manifest, outputDirectory, kinds: new Set() };
  for (const command of manifest.uploadCommands) {
    validateCommand(command, context);
  }
  if (!hasBothUploads(context.kinds)) {
    throw new Error(expectedCommands);
  }
  return manifest.uploadCommands;
}

function silentSkip(output) {
  if (output.includes('No dSYM bundles found')) {
    return true;
  }
  if (output.includes('No dSYMs to upload')) {
    return true;
  }
  return output.includes('nothing was uploaded');
}

export function uploadSucceeded(kind, status, output) {
  if (status !== 0) {
    return false;
  }
  if (silentSkip(output)) {
    return false;
  }
  if (kind === 'hermes') {
    return true;
  }
  return output.includes('dSYM upload complete');
}

function plist(file, key) {
  const result = spawnSync(
    '/usr/libexec/PlistBuddy',
    ['-c', `Print :${key}`, file],
    { encoding: 'utf8' },
  );
  if (result.status !== 0) {
    throw new Error('Archive Info.plist is missing release coordinates.');
  }
  return result.stdout.trim();
}

function evidenceDirectory(pointer, platform, repoRoot) {
  const recorded = readFileSync(pointer, 'utf8').trim();
  const evidence = realpathSync(recorded);
  const artifacts = realpathSync(path.join(repoRoot, 'artifacts/testflight'));
  if (
    evidence !== artifacts &&
    !evidence.startsWith(`${artifacts}${path.sep}`)
  ) {
    throw new Error(
      'Symbol evidence is outside the TestFlight artifact directory.',
    );
  }
  const status = readFileSync(path.join(evidence, 'status.txt'), 'utf8');
  if (!status.split('\n').includes(`Uploaded: ${platform}`)) {
    throw new Error(
      `Refusing to upload symbols: ${platform} was not uploaded from this archive.`,
    );
  }
  return evidence;
}

function macosLayout(app) {
  return {
    resources: path.join(app, 'Contents/Resources'),
    binary: path.join(app, 'Contents/MacOS/UnwiredMail'),
    info: path.join(app, 'Contents/Info.plist'),
  };
}

function iosLayout(app) {
  return {
    resources: app,
    binary: path.join(app, 'UnwiredMail'),
    info: path.join(app, 'Info.plist'),
  };
}

function archiveInputs(evidence, platform) {
  const archive = path.join(evidence, `${platform}.xcarchive`);
  const applications = path.join(archive, 'Products/Applications');
  const apps = readdirSync(applications).filter((name) =>
    name.endsWith('.app'),
  );
  if (apps.length !== 1) {
    throw new Error('Expected one archived app.');
  }
  const app = path.join(applications, apps[0]);
  const layout = platform === 'macos' ? macosLayout(app) : iosLayout(app);
  return {
    bundle: path.join(layout.resources, 'main.jsbundle'),
    map: path.join(evidence, `${platform}-sources/main.jsbundle.map`),
    binary: layout.binary,
    dsym: path.join(archive, 'dSYMs', `${apps[0]}.dSYM`),
    version: plist(layout.info, 'CFBundleShortVersionString'),
    build: plist(layout.info, 'CFBundleVersion'),
  };
}

function run(command, args, env) {
  return spawnSync(command, args, {
    cwd: tmpdir(),
    encoding: 'utf8',
    env,
    maxBuffer: 10 * 1024 * 1024,
  });
}

function blank(value) {
  if (typeof value === 'string') {
    return value;
  }
  return '';
}

function combinedOutput(result) {
  return `${blank(result.stdout)}${blank(result.stderr)}`;
}

function supportedPlatform(platform) {
  if (platform === 'ios') {
    return true;
  }
  return platform === 'macos';
}

function readOptions() {
  const { values } = parseArgs({
    options: {
      platform: { type: 'string' },
      'evidence-path': { type: 'string' },
      cli: { type: 'string' },
      help: { type: 'boolean' },
    },
  });
  if (values.help) {
    process.stdout.write(
      'Upload the signed archive Hermes map and dSYM. Requires POSTHOG_CLI_API_KEY, POSTHOG_CLI_PROJECT_ID and POSTHOG_CLI_HOST=https://eu.posthog.com.\n',
    );
    return null;
  }
  return values;
}

function requireCredentials() {
  const failure = credentialFailure(process.env);
  if (failure) {
    throw new Error(failure);
  }
  return process.env.POSTHOG_CLI_API_KEY;
}

function requirePaths(values) {
  if (!values['evidence-path']) {
    throw new Error('Symbol upload requires --evidence-path and --cli.');
  }
  if (!values.cli) {
    throw new Error('Symbol upload requires --evidence-path and --cli.');
  }
  if (!path.isAbsolute(values.cli)) {
    throw new Error('PostHog CLI path must be absolute.');
  }
}

function requireCliVersion(cli) {
  const version = run(cli, ['--version'], versionEnvironment(process.env));
  const failed = version.status !== 0;
  const mismatch = !cliVersionMatches(combinedOutput(version));
  if (failed || mismatch) {
    throw new Error(
      `PostHog CLI ${cliVersion} is required before symbol upload.`,
    );
  }
}

function preparationError(stderr, key) {
  const detail = blank(stderr).trim();
  if (detail.length > 0) {
    return redact(detail, key);
  }
  return 'Release symbol preparation failed.';
}

function unfinished(kind) {
  if (kind === 'hermes') {
    return 'Hermes source map upload did not finish.';
  }
  return 'dSYM upload did not finish.';
}

function prepareArtifacts(request) {
  const preparation = run(
    process.execPath,
    [
      fileURLToPath(new URL('reporting-artifacts.mjs', import.meta.url)),
      '--platform',
      request.platform,
      '--version',
      request.inputs.version,
      '--build',
      request.inputs.build,
      '--bundle',
      request.inputs.bundle,
      '--map',
      request.inputs.map,
      '--binary',
      request.inputs.binary,
      '--dsym',
      request.inputs.dsym,
      '--output',
      request.output,
    ],
    versionEnvironment(process.env),
  );
  if (preparation.status !== 0) {
    throw new Error(preparationError(preparation.stderr, request.key));
  }
  return decodeManifest(
    readFileSync(path.join(request.output, 'manifest.json'), 'utf8'),
  );
}

function runUpload(cli, command, context) {
  const kind = commandKind(command);
  const result = run(cli, command.slice(1), context.env);
  const outputText = redact(combinedOutput(result), context.key);
  process.stderr.write(outputText);
  if (!uploadSucceeded(kind, result.status, outputText)) {
    throw new Error(unfinished(kind));
  }
}

function uploadPrepared(cli, commands, key) {
  const context = { env: uploadEnvironment(process.env), key };
  for (const command of commands) {
    runUpload(cli, command, context);
  }
}

function uploadArchive(values, key) {
  requireCliVersion(values.cli);
  const evidence = evidenceDirectory(
    values['evidence-path'],
    values.platform,
    process.cwd(),
  );
  const inputs = archiveInputs(evidence, values.platform);
  const parent = mkdtempSync(path.join(tmpdir(), 'unwired-symbols-'));
  const output = path.join(parent, 'prepared');
  try {
    const manifest = prepareArtifacts({
      platform: values.platform,
      inputs,
      output,
      key,
    });
    uploadPrepared(values.cli, planUploads(manifest, output), key);
    appendFileSync(
      path.join(evidence, 'status.txt'),
      `Symbols: ${values.platform}; Hermes map and dSYM uploaded\n`,
    );
    process.stdout.write(
      `Uploaded ${values.platform} Hermes map and dSYM for ${manifest.appVersion} (${manifest.build}).\n`,
    );
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}

function main() {
  const values = readOptions();
  if (!values) {
    return;
  }
  const key = requireCredentials();
  requirePaths(values);
  if (!supportedPlatform(values.platform)) {
    throw new Error('Symbol upload platform must be ios or macos.');
  }
  uploadArchive(values, key);
}

const invoked =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if (invoked) {
  try {
    main();
  } catch (error) {
    const message =
      error instanceof Error ? error.message : 'Symbol upload failed.';
    process.stderr.write(
      `${redact(message, process.env.POSTHOG_CLI_API_KEY)}\n`,
    );
    process.exitCode = 1;
  }
}
