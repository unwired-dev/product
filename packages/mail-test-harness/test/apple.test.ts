import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import {
  createMailTestSimulator,
  createNamedMailTestSimulator,
  deleteOwnedSimulator,
  deleteOwnedSimulatorIntent,
  launchManualMailTestApplication,
  prepareMailTestSimulator,
  resetManualMailTestApplication,
  runMailTestApplication,
  runScheduledSendDeterministicTests,
} from '../src/apple.ts';

function result(stdout = ''): { stderr: string; stdout: string } {
  return { stderr: '', stdout };
}

type TestCommandRunner = (
  command: string,
  arguments_: readonly string[],
) => Promise<{ stderr: string; stdout: string }>;

const scheduledSendTestIdentifiers = [
  'OutboxDeliveryServiceTests/testScheduledSendNeverHandsOffEarlyAndResumesAfterRestart()',
  'OutboxDeliveryServiceTests/testScheduledSendBecomesNeedsAttentionAfterTwentyFourHoursWithoutHandoff()',
  'OutboxDeliveryServiceTests/testEditAndCancelLoseRaceOnceProviderHandoffStarts()',
  'OutboxDeliveryServiceTests/dueScheduledSendRetainsRetryCleanupAfterATransientFailure()',
  'OutboxDeliveryServiceTests/testPermanentGraphFailureDeletesProviderDraftWithoutChangingFailureOutcome()',
  'SendReminderSyncServiceTests/reminderAndDraftSynchronizeWithinOneProfileAndTransferOwnership()',
  'SwiftMailEngineTests/testSMTPAmbiguousPostContentFailureIsNeverRetryable()',
  'OutboxDeliveryServiceTests/microsoftGraphScheduledSendAdmissionPreservesItsPayloadAndConnection()',
  'OutboxDeliveryServiceTests/exchangeWebServicesScheduledSendAdmissionPreservesItsPayloadAndConnection()',
  'OutboxDeliveryServiceTests/standardsMailScheduledSendAdmissionPreservesItsPayloadAndConnection()',
  'ScheduledSendReleasePolicyTests/newSchedulingIsEnabledAfterProtectedProviderCompatibilityCompletes()',
];

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
        environment: {
          MAIL_TEST_COORDINATION_URL: 'http://127.0.0.1:8080/milestone',
        },
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
      [
        'simctl',
        'spawn',
        simulator.udid,
        'launchctl',
        'setenv',
        'MAIL_TEST_COORDINATION_URL',
        'http://127.0.0.1:8080/milestone',
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

  it('writes XCTest result bundles to the requested evidence directory', async () => {
    expect.assertions(1);
    const evidenceDirectory = await mkdtemp(
      path.join(tmpdir(), 'mail-test-evidence-'),
    );
    const run = vi.fn<TestCommandRunner>(async () => result());

    try {
      await runMailTestApplication(
        {
          resultBundleDirectory: evidenceDirectory,
          root: '/tmp/run',
          simulator: {
            name: 'Unwired Mail Test run',
            runtime: 'iOS 26.5',
            udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
          },
          testName: 'testSyntheticMessageAppearsInVisibleMailbox',
        },
        run,
      );

      expect(run.mock.calls[0]?.[1]).toStrictEqual(
        expect.arrayContaining([
          '-resultBundlePath',
          path.join(
            evidenceDirectory,
            'testSyntheticMessageAppearsInVisibleMailbox.xcresult',
          ),
        ]),
      );
    } finally {
      await rm(evidenceDirectory, { force: true, recursive: true });
    }
  });

  it('runs the requested visible send step on the exact owned simulator', async () => {
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
          step: 'compose-send',
        },
        run,
      ),
    ).resolves.toBe('performed');

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
        '-only-testing:unwired-mailMailTestUITests/MailTestBootstrapUITests/testComposeAndSendThroughVisibleClient',
      ],
      { signal: undefined },
    );
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

    expect(run.mock.calls[0]?.[1]).toContain(
      '-only-testing:unwired-mailMailTestUITests/MailTestBootstrapUITests/testCategorizedFixturesAppearInVisibleMailbox',
    );
  });

  it('requires every selected Scheduled Send deterministic test to execute', async () => {
    expect.assertions(4);
    const evidenceDirectory = await mkdtemp(
      path.join(tmpdir(), 'scheduled-send-evidence-'),
    );
    const summary = JSON.stringify({
      failedTests: 0,
      passedTests: 184,
      result: 'Passed',
      skippedTests: 0,
      totalTestCount: 184,
    });
    const tests = JSON.stringify({
      testNodes: [
        {
          children: [
            {
              children: scheduledSendTestIdentifiers.map((nodeIdentifier) => ({
                nodeIdentifier,
                nodeType: 'Test Case',
                result: 'Passed',
              })),
            },
          ],
        },
      ],
    });
    const run = vi.fn<TestCommandRunner>();
    run
      .mockResolvedValueOnce(result())
      .mockResolvedValueOnce(result(summary))
      .mockResolvedValueOnce(result(tests));

    try {
      await expect(
        runScheduledSendDeterministicTests(
          {
            resultBundleDirectory: evidenceDirectory,
            root: '/tmp/run',
            simulator: {
              name: 'Unwired Mail Test run',
              runtime: 'iOS 26.5',
              udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
            },
          },
          run,
        ),
      ).resolves.toBe(11);
      expect(run.mock.calls[0]?.[1]).toStrictEqual(
        expect.arrayContaining([
          '-scheme',
          'unwired-mail',
          '-destination',
          'id=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
          '-resultBundlePath',
          path.join(evidenceDirectory, 'scheduled-send-deterministic.xcresult'),
          '-only-testing:unwired-mailTests/SwiftMailEngineTests',
        ]),
      );
      expect(run.mock.calls[1]).toStrictEqual([
        'xcrun',
        [
          'xcresulttool',
          'get',
          'test-results',
          'summary',
          '--path',
          path.join(evidenceDirectory, 'scheduled-send-deterministic.xcresult'),
          '--compact',
        ],
        { signal: undefined },
      ]);
      expect(run.mock.calls[2]?.[1]).toStrictEqual([
        'xcresulttool',
        'get',
        'test-results',
        'tests',
        '--path',
        path.join(evidenceDirectory, 'scheduled-send-deterministic.xcresult'),
        '--compact',
      ]);
    } finally {
      await rm(evidenceDirectory, { force: true, recursive: true });
    }
  });

  it('rejects Scheduled Send deterministic evidence when a selected test did not execute', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>();
    run.mockResolvedValueOnce(result()).mockResolvedValueOnce(
      result(
        JSON.stringify({
          failedTests: 0,
          passedTests: 9,
          result: 'Passed',
          skippedTests: 0,
          totalTestCount: 9,
        }),
      ),
    );

    await expect(
      runScheduledSendDeterministicTests(
        {
          root: '/tmp/run',
          simulator: {
            name: 'Unwired Mail Test run',
            runtime: 'iOS 26.5',
            udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
          },
        },
        run,
      ),
    ).rejects.toThrow('selected 9 tests; expected at least 11 passing tests');
  });

  it('rejects Scheduled Send deterministic evidence missing a required identifier', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>();
    run
      .mockResolvedValueOnce(result())
      .mockResolvedValueOnce(
        result(
          JSON.stringify({
            failedTests: 0,
            passedTests: 11,
            result: 'Passed',
            skippedTests: 0,
            totalTestCount: 11,
          }),
        ),
      )
      .mockResolvedValueOnce(
        result(
          JSON.stringify({
            testNodes: [
              {
                children: [
                  {
                    children: scheduledSendTestIdentifiers
                      .slice(1)
                      .map((nodeIdentifier) => ({
                        nodeIdentifier,
                        nodeType: 'Test Case',
                        result: 'Passed',
                      })),
                  },
                ],
              },
            ],
          }),
        ),
      );

    await expect(
      runScheduledSendDeterministicTests(
        {
          root: '/tmp/run',
          simulator: {
            name: 'Unwired Mail Test run',
            runtime: 'iOS 26.5',
            udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
          },
        },
        run,
      ),
    ).rejects.toThrow(scheduledSendTestIdentifiers[0]);
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

  it('retains structured semantic UI context for a failed visible step', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>(async () => {
      throw new Error(
        'MAIL_TEST_FAILURE:move:move-destination-not-presented: Move Target was not available.',
      );
    });

    await expect(
      runMailTestApplication(
        {
          root: '/tmp/run',
          simulator: {
            name: 'Unwired Mail Test run',
            runtime: 'iOS 26.5',
            udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
          },
          step: 'move',
        },
        run,
      ),
    ).rejects.toMatchObject({
      semanticUIState: 'move-destination-not-presented',
      name: 'MailTestVisibleStepFailureError',
      serverAssertion: 'not-run',
      step: 'move',
    });
  });

  it('retains the final structured semantic UI context for a failed visible step', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>(async () => {
      throw new Error(
        [
          'MAIL_TEST_FAILURE:move:message-row-not-presented: The message did not appear.',
          'MAIL_TEST_FAILURE:move:move-destination-not-presented: Move Target was not available.',
        ].join('\n'),
      );
    });

    await expect(
      runMailTestApplication(
        {
          root: '/tmp/run',
          simulator: {
            name: 'Unwired Mail Test run',
            runtime: 'iOS 26.5',
            udid: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
          },
          step: 'move',
        },
        run,
      ),
    ).rejects.toMatchObject({
      semanticUIState: 'move-destination-not-presented',
    });
  });

  it('reports an explicitly unavailable send capability', async () => {
    expect.assertions(2);
    const run = vi.fn<TestCommandRunner>(async () =>
      result('MAIL_TEST_CAPABILITY_UNAVAILABLE:reply\n'),
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
          step: 'reply',
        },
        run,
      ),
    ).resolves.toBe('unavailable');

    expect(run.mock.calls[0]?.[1]).toContain(
      '-only-testing:unwired-mailMailTestUITests/MailTestBootstrapUITests/testReplyThroughVisibleClient',
    );
  });

  it('ignores an unavailable marker that names another send step', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>(async () =>
      result('MAIL_TEST_CAPABILITY_UNAVAILABLE:compose-send\n'),
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
          step: 'reply',
        },
        run,
      ),
    ).resolves.toBe('performed');
  });

  it('ignores an unavailable marker during a named scenario run', async () => {
    expect.assertions(1);
    const run = vi.fn<TestCommandRunner>(async () =>
      result('MAIL_TEST_CAPABILITY_UNAVAILABLE:reply\n'),
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
          testName: 'testCategorizedFixturesAppearInVisibleMailbox',
        },
        run,
      ),
    ).resolves.toBe('performed');
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
