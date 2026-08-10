import {
  createMailTestSimulator,
  createNamedMailTestSimulator,
  deleteOwnedSimulator,
  deleteOwnedSimulatorIntent,
  launchManualMailTestApplication,
  prepareMailTestSimulator,
  resetManualMailTestApplication,
  runMailTestApplication,
} from '../src/apple.ts';

function result(stdout = ''): { stderr: string; stdout: string } {
  return { stderr: '', stdout };
}

type TestCommandRunner = (
  command: string,
  arguments_: readonly string[],
) => Promise<{ stderr: string; stdout: string }>;

describe('mail test device lifecycle', () => {
  it('creates a persistent simulator with the requested sandbox name', async () => {
    expect.assertions(2);
    const responses = new Map([
      [
        'simctl create Unwired Mail Manual Sandbox run device-type-17 com.apple.CoreSimulator.SimRuntime.iOS-26-5',
        'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
      ],
      [
        'simctl list devicetypes --json',
        JSON.stringify({
          devicetypes: [{ identifier: 'device-type-17', name: 'iPhone 17' }],
        }),
      ],
      [
        'simctl list runtimes --json',
        JSON.stringify({
          runtimes: [
            {
              identifier: 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
              isAvailable: true,
              name: 'iOS 26.5',
              version: '26.5',
            },
          ],
        }),
      ],
    ]);
    const run = vi.fn<TestCommandRunner>(async (_command, arguments_) =>
      result(responses.get(arguments_.join(' '))),
    );

    await expect(
      createNamedMailTestSimulator(
        'Unwired Mail Manual Sandbox run',
        undefined,
        run,
      ),
    ).resolves.toStrictEqual({
      name: 'Unwired Mail Manual Sandbox run',
      runtime: 'iOS 26.5',
      udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
    });
    expect(run).toHaveBeenCalledWith(
      'xcrun',
      [
        'simctl',
        'create',
        'Unwired Mail Manual Sandbox run',
        'device-type-17',
        'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
      ],
      { signal: undefined },
    );
  });

  it('rejects a malformed Simulator UDID', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>();
    run
      .mockResolvedValueOnce(
        result(
          JSON.stringify({
            devicetypes: [{ identifier: 'device-type-17', name: 'iPhone 17' }],
          }),
        ),
      )
      .mockResolvedValueOnce(
        result(
          JSON.stringify({
            runtimes: [
              {
                identifier: 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
                isAvailable: true,
                name: 'iOS 26.5',
                version: '26.5',
              },
            ],
          }),
        ),
      )
      .mockResolvedValueOnce(result('not-a-udid\n'));

    await expect(
      createNamedMailTestSimulator(
        'Unwired Mail Manual Sandbox run',
        undefined,
        run,
      ),
    ).rejects.toThrow('did not return a valid Simulator UDID');
  });

  it('creates the newest available iPhone 17 simulator', async () => {
    expect.assertions(2);
    const run = vi.fn<TestCommandRunner>();
    run
      .mockResolvedValueOnce(
        result(
          JSON.stringify({
            devicetypes: [{ identifier: 'device-type-17', name: 'iPhone 17' }],
          }),
        ),
      )
      .mockResolvedValueOnce(
        result(
          JSON.stringify({
            runtimes: [
              {
                identifier: 'com.apple.CoreSimulator.SimRuntime.iOS-26-4',
                isAvailable: true,
                name: 'iOS 26.4',
                version: '26.4',
              },
              {
                identifier: 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
                isAvailable: true,
                name: 'iOS 26.5',
                version: '26.5',
              },
            ],
          }),
        ),
      )
      .mockResolvedValueOnce(result('AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\n'));

    await expect(
      createMailTestSimulator(
        '00000000-0000-0000-0000-000000000001',
        undefined,
        run,
      ),
    ).resolves.toStrictEqual({
      name: 'Unwired Mail Test 00000000-0000-0000-0000-000000000001',
      runtime: 'iOS 26.5',
      udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
    });
    expect(run).toHaveBeenLastCalledWith(
      'xcrun',
      [
        'simctl',
        'create',
        'Unwired Mail Test 00000000-0000-0000-0000-000000000001',
        'device-type-17',
        'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
      ],
      { signal: undefined },
    );
  });

  it('boots, trusts, and configures only the owned simulator', async () => {
    expect.assertions(1);
    const commands: string[][] = [];
    const run = vi.fn<TestCommandRunner>(async (_command, args) => {
      commands.push([...args]);
      return result();
    });
    const simulator = {
      name: 'Unwired Mail Test run',
      runtime: 'iOS 26.5',
      udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
    };

    await prepareMailTestSimulator(
      simulator,
      {
        certificatePath: '/tmp/run/ca.pem',
        host: '127.0.0.1',
        imapsPort: 1993,
        runId: '00000000-0000-0000-0000-000000000001',
        scenario: 'categorization',
        smtpsPort: 1465,
      },
      run,
    );

    expect(commands).toStrictEqual([
      ['simctl', 'boot', simulator.udid],
      ['simctl', 'bootstatus', simulator.udid, '-b'],
      [
        'simctl',
        'keychain',
        simulator.udid,
        'add-root-cert',
        '/tmp/run/ca.pem',
      ],
      [
        'simctl',
        'spawn',
        simulator.udid,
        'launchctl',
        'setenv',
        'MAIL_TEST_BOOTSTRAP',
        '1',
      ],
      [
        'simctl',
        'spawn',
        simulator.udid,
        'launchctl',
        'setenv',
        'MAIL_TEST_HOST',
        '127.0.0.1',
      ],
      [
        'simctl',
        'spawn',
        simulator.udid,
        'launchctl',
        'setenv',
        'MAIL_TEST_IMAPS_PORT',
        '1993',
      ],
      [
        'simctl',
        'spawn',
        simulator.udid,
        'launchctl',
        'setenv',
        'MAIL_TEST_RUN_ID',
        '00000000-0000-0000-0000-000000000001',
      ],
      [
        'simctl',
        'spawn',
        simulator.udid,
        'launchctl',
        'setenv',
        'MAIL_TEST_SCENARIO',
        'categorization',
      ],
      [
        'simctl',
        'spawn',
        simulator.udid,
        'launchctl',
        'setenv',
        'MAIL_TEST_SMTPS_PORT',
        '1465',
      ],
    ]);
  });

  it('passes scenario expectations only to the owned simulator', async () => {
    expect.assertions(1);
    const commands: string[][] = [];
    const run = vi.fn<TestCommandRunner>(async (_command, args) => {
      commands.push([...args]);
      return result();
    });

    await prepareMailTestSimulator(
      {
        name: 'Unwired Mail Test run',
        runtime: 'iOS 26.5',
        udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
      },
      {
        additionalEnvironment: {
          MAIL_TEST_SCENARIO_FIXTURES: 'encoded-expectations',
        },
        certificatePath: '/tmp/run/ca.pem',
        host: '127.0.0.1',
        imapsPort: 1993,
        runId: '00000000-0000-0000-0000-000000000001',
        scenario: 'message-content',
        smtpsPort: 1465,
      },
      run,
    );

    expect(commands).toContainEqual([
      'simctl',
      'spawn',
      'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
      'launchctl',
      'setenv',
      'MAIL_TEST_SCENARIO_FIXTURES',
      'encoded-expectations',
    ]);
  });

  it('runs the dedicated UI assertion on the exact owned simulator', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>(async () => result());

    await runMailTestApplication(
      {
        root: '/tmp/run',
        simulator: {
          name: 'Unwired Mail Test run',
          runtime: 'iOS 26.5',
          udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
        },
        testName: 'testCategorizedFixturesAppearInVisibleMailbox',
      },
      run,
    );

    expect(run).toHaveBeenCalledWith(
      'xcodebuild',
      [
        'test',
        '-project',
        expect.stringContaining('apps/unwired-mail/unwired-mail.xcodeproj'),
        '-scheme',
        'unwired-mail-mail-test',
        '-destination',
        'id=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
        '-derivedDataPath',
        '/tmp/run/DerivedData',
        '-clonedSourcePackagesDirPath',
        '/tmp/run/SourcePackages',
        '-parallel-testing-enabled',
        'NO',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG MAIL_TEST_BOOTSTRAP',
        '-only-testing:unwired-mailMailTestUITests/MailTestBootstrapUITests/testCategorizedFixturesAppearInVisibleMailbox',
      ],
      { signal: undefined },
    );
  });

  it('runs the requested UI step on the exact owned simulator', async () => {
    expect.assertions(2);
    const run = vi.fn<TestCommandRunner>(async () => result());

    await expect(
      runMailTestApplication(
        {
          root: '/tmp/run',
          simulator: {
            name: 'Unwired Mail Test run',
            runtime: 'iOS 26.5',
            udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
          },
          step: 'open',
        },
        run,
      ),
    ).resolves.toBe('performed');

    expect(run.mock.calls[0]?.[1]).toContain(
      '-only-testing:unwired-mailMailTestUITests/MailTestBootstrapUITests/testOpenMessageThroughVisibleClient',
    );
  });

  it('reports an explicitly skipped provider capability', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>(async () =>
      result('MAIL_TEST_CAPABILITY_UNAVAILABLE:archive\n'),
    );

    await expect(
      runMailTestApplication(
        {
          root: '/tmp/run',
          simulator: {
            name: 'Unwired Mail Test run',
            runtime: 'iOS 26.5',
            udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
          },
          step: 'archive',
        },
        run,
      ),
    ).resolves.toBe('unavailable');
  });

  it('can select the message-content UI assertion', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>(async () => result());

    await runMailTestApplication(
      {
        root: '/tmp/run',
        simulator: {
          name: 'Unwired Mail Test run',
          runtime: 'iOS 26.5',
          udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
        },
        testName: 'testMessageContentCorpusInVisibleMailbox',
      },
      run,
    );

    expect(run.mock.calls[0]?.[1]).toContain(
      '-only-testing:unwired-mailMailTestUITests/MailTestBootstrapUITests/testMessageContentCorpusInVisibleMailbox',
    );
  });

  it('builds, installs, and launches the manual sandbox app', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>(async () => result());

    await launchManualMailTestApplication(
      {
        root: '/tmp/manual-sandbox',
        simulator: {
          name: 'Unwired Mail Manual Sandbox run',
          runtime: 'iOS 26.5',
          udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
        },
      },
      run,
    );

    expect(run.mock.calls).toStrictEqual([
      [
        'xcodebuild',
        [
          'build',
          '-project',
          expect.stringContaining('apps/unwired-mail/unwired-mail.xcodeproj'),
          '-scheme',
          'unwired-mail-mail-test',
          '-configuration',
          'Debug',
          '-destination',
          'id=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
          '-derivedDataPath',
          '/tmp/manual-sandbox/DerivedData',
          '-clonedSourcePackagesDirPath',
          '/tmp/manual-sandbox/SourcePackages',
          'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG MAIL_TEST_BOOTSTRAP',
        ],
        { signal: undefined },
      ],
      [
        'xcrun',
        [
          'simctl',
          'install',
          'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
          '/tmp/manual-sandbox/DerivedData/Build/Products/Debug-iphonesimulator/unwired-mail.app',
        ],
        { signal: undefined },
      ],
      [
        'xcrun',
        [
          'simctl',
          'launch',
          'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
          'dev.unwired.mail',
        ],
        { signal: undefined },
      ],
    ]);
  });

  it('clears local app state before relaunching the sandbox app', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>(async () => result());
    const simulator = {
      name: 'Unwired Mail Manual Sandbox run',
      runtime: 'iOS 26.5',
      udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
    };

    await resetManualMailTestApplication(
      { root: '/tmp/manual-sandbox', simulator },
      run,
    );

    expect(run.mock.calls).toStrictEqual([
      [
        'xcrun',
        ['simctl', 'bootstatus', simulator.udid, '-b'],
        { signal: undefined },
      ],
      [
        'xcrun',
        ['simctl', 'uninstall', simulator.udid, 'dev.unwired.mail'],
        { signal: undefined },
      ],
      [
        'xcrun',
        [
          'simctl',
          'install',
          simulator.udid,
          '/tmp/manual-sandbox/DerivedData/Build/Products/Debug-iphonesimulator/unwired-mail.app',
        ],
        { signal: undefined },
      ],
      [
        'xcrun',
        ['simctl', 'launch', simulator.udid, 'dev.unwired.mail'],
        { signal: undefined },
      ],
    ]);
  });

  it('shuts down and deletes the exact owned simulator', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>();
    run
      .mockResolvedValueOnce(
        result(
          JSON.stringify({
            devices: {
              'runtime-26-5': [
                {
                  name: 'Unwired Mail Test run',
                  state: 'Booted',
                  udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
                },
              ],
            },
          }),
        ),
      )
      .mockResolvedValue(result());

    await deleteOwnedSimulator(
      {
        name: 'Unwired Mail Test run',
        runtime: 'iOS 26.5',
        udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
      },
      run,
    );

    expect(run.mock.calls).toStrictEqual([
      ['xcrun', ['simctl', 'list', 'devices', '--json']],
      ['xcrun', ['simctl', 'shutdown', 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE']],
      ['xcrun', ['simctl', 'delete', 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE']],
    ]);
  });

  it('recovers only the simulator matching the persisted intent name', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>();
    run
      .mockResolvedValueOnce(
        result(
          JSON.stringify({
            devices: {
              'runtime-26-5': [
                {
                  name: 'Personal iPhone',
                  state: 'Booted',
                  udid: 'FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
                },
                {
                  name: 'Unwired Mail Test run',
                  state: 'Shutdown',
                  udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
                },
              ],
            },
          }),
        ),
      )
      .mockResolvedValue(result());

    await deleteOwnedSimulatorIntent({ name: 'Unwired Mail Test run' }, run);

    expect(run.mock.calls).toStrictEqual([
      ['xcrun', ['simctl', 'list', 'devices', '--json']],
      ['xcrun', ['simctl', 'delete', 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE']],
    ]);
  });

  it('refuses ambiguous simulator intent recovery', async () => {
    expect.assertions(2);
    const run = vi.fn<TestCommandRunner>(async () =>
      result(
        JSON.stringify({
          devices: {
            'runtime-26-5': [
              {
                name: 'Unwired Mail Test run',
                state: 'Booted',
                udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
              },
              {
                name: 'Unwired Mail Test run',
                state: 'Shutdown',
                udid: 'FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
              },
            ],
          },
        }),
      ),
    );

    await expect(
      deleteOwnedSimulatorIntent({ name: 'Unwired Mail Test run' }, run),
    ).rejects.toThrow('ambiguous Simulator intent');
    expect(run.mock.calls).toStrictEqual([
      ['xcrun', ['simctl', 'list', 'devices', '--json']],
    ]);
  });

  it('refuses to delete a simulator whose name no longer matches', async () => {
    expect.assertions(2);
    const run = vi.fn<TestCommandRunner>(async () =>
      result(
        JSON.stringify({
          devices: {
            'runtime-26-5': [
              {
                name: 'Personal iPhone',
                state: 'Shutdown',
                udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
              },
            ],
          },
        }),
      ),
    );

    await expect(
      deleteOwnedSimulator(
        {
          name: 'Unwired Mail Test run',
          runtime: 'iOS 26.5',
          udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
        },
        run,
      ),
    ).rejects.toThrow('name no longer matches');
    expect(run.mock.calls).toStrictEqual([
      ['xcrun', ['simctl', 'list', 'devices', '--json']],
    ]);
  });
});
