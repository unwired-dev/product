import {
  createMailTestSimulator,
  deleteOwnedSimulator,
  prepareMailTestSimulator,
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
        smtpsPort: 1465,
      },
      run,
    );

    expect(commands).toContainEqual([
      'simctl',
      'keychain',
      simulator.udid,
      'add-root-cert',
      '/tmp/run/ca.pem',
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
      },
      run,
    );

    expect(run).toHaveBeenCalledWith(
      'xcodebuild',
      expect.arrayContaining([
        '-destination',
        'id=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG MAIL_TEST_BOOTSTRAP',
      ]),
      { signal: undefined },
    );
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
