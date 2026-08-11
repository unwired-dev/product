import path from 'node:path';
import { fileURLToPath } from 'node:url';

import type { OwnedSimulator, OwnedSimulatorIntent } from './ownership.ts';
import type { CommandResult } from './process.ts';

import { runCommand } from './process.ts';

type CommandRunner = (
  command: string,
  arguments_: readonly string[],
  options?: { env?: NodeJS.ProcessEnv; signal?: AbortSignal },
) => Promise<CommandResult>;

interface SimulatorDeviceType {
  identifier: string;
  name: string;
}

interface SimulatorRuntime {
  identifier: string;
  isAvailable: boolean;
  name: string;
  version: string;
}

interface SimulatorDevice {
  name: string;
  state: string;
  udid: string;
}

const REPOSITORY_ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const DEVICE_NAME = 'iPhone 17';
const MANUAL_APP_RELATIVE_PATH =
  'DerivedData/Build/Products/Debug-iphonesimulator/unwired-mail.app';
const MANUAL_APP_BUNDLE_IDENTIFIER = 'dev.unwired.mail';

export function mailTestSimulatorIntent(runId: string): OwnedSimulatorIntent {
  return { name: `Unwired Mail Test ${runId}` };
}

export async function createMailTestSimulator(
  runId: string,
  signal?: AbortSignal,
  run: CommandRunner = runCommand,
): Promise<OwnedSimulator> {
  return createNamedMailTestSimulator(
    mailTestSimulatorIntent(runId).name,
    signal,
    run,
  );
}

export async function createNamedMailTestSimulator(
  name: string,
  signal?: AbortSignal,
  run: CommandRunner = runCommand,
): Promise<OwnedSimulator> {
  const [deviceTypes, runtimes] = await Promise.all([
    run('xcrun', ['simctl', 'list', 'devicetypes', '--json'], { signal }),
    run('xcrun', ['simctl', 'list', 'runtimes', '--json'], { signal }),
  ]);
  const deviceType = parseDeviceTypes(deviceTypes.stdout).find(
    (candidate) => candidate.name === DEVICE_NAME,
  );
  if (deviceType === undefined) {
    throw new Error(
      `Mail Test Device unavailable: install an Xcode runtime that supports ${DEVICE_NAME}.`,
    );
  }
  const runtime = newestAvailableIOSRuntime(parseRuntimes(runtimes.stdout));
  if (runtime === undefined) {
    throw new Error(
      'Mail Test Device unavailable: install an available iOS Simulator runtime in Xcode.',
    );
  }
  const created = await run(
    'xcrun',
    ['simctl', 'create', name, deviceType.identifier, runtime.identifier],
    { signal },
  );
  const udid = created.stdout.trim();
  if (!/^[0-9A-F-]{36}$/u.test(udid)) {
    throw new Error(
      'Mail Test Device creation did not return a valid Simulator UDID.',
    );
  }
  return { name, runtime: runtime.name, udid };
}

export async function prepareMailTestSimulator(
  simulator: Readonly<OwnedSimulator>,
  options: {
    additionalEnvironment?: Readonly<Record<string, string>>;
    certificatePath: string;
    environment?: Readonly<Record<string, string>>;
    host: string;
    imapsPort: number;
    runId: string;
    scenario:
      | 'categorization'
      | 'core-mail-loop'
      | 'incremental-arrival'
      | 'message-content';
    signal?: AbortSignal;
    smtpsPort: number;
  },
  run: CommandRunner = runCommand,
): Promise<void> {
  await run('xcrun', ['simctl', 'boot', simulator.udid], {
    signal: options.signal,
  });
  await run('xcrun', ['simctl', 'bootstatus', simulator.udid, '-b'], {
    signal: options.signal,
  });
  await run(
    'xcrun',
    [
      'simctl',
      'keychain',
      simulator.udid,
      'add-root-cert',
      options.certificatePath,
    ],
    { signal: options.signal },
  );
  const environment = {
    ...options.additionalEnvironment,
    MAIL_TEST_BOOTSTRAP: '1',
    MAIL_TEST_HOST: options.host,
    MAIL_TEST_IMAPS_PORT: String(options.imapsPort),
    MAIL_TEST_RUN_ID: options.runId,
    MAIL_TEST_SCENARIO: options.scenario,
    MAIL_TEST_SMTPS_PORT: String(options.smtpsPort),
    ...options.environment,
  };
  for (const [key, value] of Object.entries(environment)) {
    await run(
      'xcrun',
      ['simctl', 'spawn', simulator.udid, 'launchctl', 'setenv', key, value],
      { signal: options.signal },
    );
  }
}

export async function runMailTestApplication(
  options: {
    root: string;
    signal?: AbortSignal;
    simulator: Readonly<OwnedSimulator>;
    testName: string;
  },
  run: CommandRunner = runCommand,
): Promise<void> {
  await run(
    'xcodebuild',
    [
      'test',
      '-project',
      path.join(REPOSITORY_ROOT, 'apps/unwired-mail/unwired-mail.xcodeproj'),
      '-scheme',
      'unwired-mail-mail-test',
      '-destination',
      `id=${options.simulator.udid}`,
      '-derivedDataPath',
      path.join(options.root, 'DerivedData'),
      '-clonedSourcePackagesDirPath',
      path.join(options.root, 'SourcePackages'),
      '-parallel-testing-enabled',
      'NO',
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG MAIL_TEST_BOOTSTRAP',
      `-only-testing:unwired-mailMailTestUITests/MailTestBootstrapUITests/${options.testName}`,
    ],
    { signal: options.signal },
  );
}

export async function launchManualMailTestApplication(
  options: {
    root: string;
    signal?: AbortSignal;
    simulator: Readonly<OwnedSimulator>;
  },
  run: CommandRunner = runCommand,
): Promise<void> {
  await run(
    'xcodebuild',
    [
      'build',
      '-project',
      path.join(REPOSITORY_ROOT, 'apps/unwired-mail/unwired-mail.xcodeproj'),
      '-scheme',
      'unwired-mail-mail-test',
      '-configuration',
      'Debug',
      '-destination',
      `id=${options.simulator.udid}`,
      '-derivedDataPath',
      path.join(options.root, 'DerivedData'),
      '-clonedSourcePackagesDirPath',
      path.join(options.root, 'SourcePackages'),
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG MAIL_TEST_BOOTSTRAP',
    ],
    { signal: options.signal },
  );
  await installAndLaunchManualApplication(options, run);
}

export async function resetManualMailTestApplication(
  options: {
    root: string;
    signal?: AbortSignal;
    simulator: Readonly<OwnedSimulator>;
  },
  run: CommandRunner = runCommand,
): Promise<void> {
  await run('xcrun', ['simctl', 'bootstatus', options.simulator.udid, '-b'], {
    signal: options.signal,
  });
  await run(
    'xcrun',
    [
      'simctl',
      'uninstall',
      options.simulator.udid,
      MANUAL_APP_BUNDLE_IDENTIFIER,
    ],
    { signal: options.signal },
  );
  await installAndLaunchManualApplication(options, run);
}

async function installAndLaunchManualApplication(
  options: {
    root: string;
    signal?: AbortSignal;
    simulator: Readonly<OwnedSimulator>;
  },
  run: CommandRunner,
): Promise<void> {
  const appPath = path.join(options.root, MANUAL_APP_RELATIVE_PATH);
  await run('xcrun', ['simctl', 'install', options.simulator.udid, appPath], {
    signal: options.signal,
  });
  await run(
    'xcrun',
    ['simctl', 'launch', options.simulator.udid, MANUAL_APP_BUNDLE_IDENTIFIER],
    { signal: options.signal },
  );
}

export async function deleteOwnedSimulator(
  expected: Readonly<OwnedSimulator>,
  run: CommandRunner = runCommand,
): Promise<void> {
  const listed = await run('xcrun', ['simctl', 'list', 'devices', '--json']);
  const actual = parseDevices(listed.stdout).find(
    (candidate) => candidate.udid === expected.udid,
  );
  if (actual === undefined) {
    return;
  }
  if (actual.name !== expected.name) {
    throw new Error(
      `Mail test cleanup refused Simulator ${expected.udid} because its name no longer matches the ownership record.`,
    );
  }
  await deleteSimulatorDevice(actual, run);
}

export async function deleteOwnedSimulatorIntent(
  expected: Readonly<OwnedSimulatorIntent>,
  run: CommandRunner = runCommand,
): Promise<void> {
  const listed = await run('xcrun', ['simctl', 'list', 'devices', '--json']);
  const matches = parseDevices(listed.stdout).filter(
    (candidate) => candidate.name === expected.name,
  );
  if (matches.length > 1) {
    throw new Error(
      `Mail test cleanup refused ambiguous Simulator intent ${expected.name}.`,
    );
  }
  const [actual] = matches;
  if (actual !== undefined) {
    await deleteSimulatorDevice(actual, run);
  }
}

async function deleteSimulatorDevice(
  actual: Readonly<SimulatorDevice>,
  run: CommandRunner,
): Promise<void> {
  if (actual.state === 'Booted') {
    await run('xcrun', ['simctl', 'shutdown', actual.udid]);
  }
  await run('xcrun', ['simctl', 'delete', actual.udid]);
}

function parseDeviceTypes(value: string): SimulatorDeviceType[] {
  const parsed: unknown = JSON.parse(value);
  if (!isRecord(parsed) || !Array.isArray(parsed.devicetypes)) {
    return [];
  }
  return parsed.devicetypes.filter(isSimulatorDeviceType);
}

function parseRuntimes(value: string): SimulatorRuntime[] {
  const parsed: unknown = JSON.parse(value);
  if (!isRecord(parsed) || !Array.isArray(parsed.runtimes)) {
    return [];
  }
  return parsed.runtimes.filter(isSimulatorRuntime);
}

function parseDevices(value: string): SimulatorDevice[] {
  const parsed: unknown = JSON.parse(value);
  if (!isRecord(parsed) || !isRecord(parsed.devices)) {
    return [];
  }
  return Object.values(parsed.devices)
    .filter(Array.isArray)
    .flat()
    .filter(isSimulatorDevice);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isSimulatorDeviceType(value: unknown): value is SimulatorDeviceType {
  return (
    isRecord(value) &&
    typeof value.identifier === 'string' &&
    typeof value.name === 'string'
  );
}

function isSimulatorRuntime(value: unknown): value is SimulatorRuntime {
  return (
    isRecord(value) &&
    typeof value.identifier === 'string' &&
    typeof value.isAvailable === 'boolean' &&
    typeof value.name === 'string' &&
    typeof value.version === 'string'
  );
}

function isSimulatorDevice(value: unknown): value is SimulatorDevice {
  return (
    isRecord(value) &&
    typeof value.name === 'string' &&
    typeof value.state === 'string' &&
    typeof value.udid === 'string'
  );
}

function newestAvailableIOSRuntime(
  runtimes: readonly SimulatorRuntime[],
): SimulatorRuntime | undefined {
  return runtimes
    .filter(
      (runtime) => runtime.isAvailable && runtime.identifier.includes('iOS'),
    )
    .toSorted((left, right) =>
      right.version.localeCompare(left.version, undefined, { numeric: true }),
    )[0];
}
