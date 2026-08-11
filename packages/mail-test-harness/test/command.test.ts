import type { CommandHandlers } from '../src/command.ts';

import { executeCommand } from '../src/command.ts';

const USAGE =
  'Usage: pnpm mail:test run <core-mail-loop|categorization|incremental-arrival|message-content> --json | pnpm mail:test doctor | pnpm mail:test readiness <inspect|require-ready> --json | pnpm mail:test sandbox <start --scenario core-mail-loop|status|inject|reset|stop>';

function handlers() {
  return {
    doctor: vi.fn<CommandHandlers['doctor']>(async () => undefined),
    readinessInspect: vi.fn<CommandHandlers['readinessInspect']>(
      async () => undefined,
    ),
    readinessRequireReady: vi.fn<CommandHandlers['readinessRequireReady']>(
      async () => undefined,
    ),
    runCategorization: vi.fn<CommandHandlers['runCategorization']>(
      async () => undefined,
    ),
    runCoreMailLoop: vi.fn<CommandHandlers['runCoreMailLoop']>(
      async () => undefined,
    ),
    runIncrementalArrival: vi.fn<CommandHandlers['runIncrementalArrival']>(
      async () => undefined,
    ),
    runMessageContent: vi.fn<CommandHandlers['runMessageContent']>(
      async () => undefined,
    ),
    sandboxInject: vi.fn<CommandHandlers['sandboxInject']>(
      async () => undefined,
    ),
    sandboxReset: vi.fn<CommandHandlers['sandboxReset']>(async () => undefined),
    sandboxStart: vi.fn<CommandHandlers['sandboxStart']>(async () => undefined),
    sandboxStatus: vi.fn<CommandHandlers['sandboxStatus']>(
      async () => undefined,
    ),
    sandboxStop: vi.fn<CommandHandlers['sandboxStop']>(async () => undefined),
  };
}

describe('mail test command dispatch', () => {
  it('delegates valid commands to the matching handler', async () => {
    expect.assertions(5);
    const { signal } = new AbortController();
    const commandHandlers = handlers();

    await executeCommand(
      ['run', 'core-mail-loop', '--json'],
      signal,
      commandHandlers,
    );
    expect({
      doctorCalls: commandHandlers.doctor.mock.calls,
      runCalls: commandHandlers.runCoreMailLoop.mock.calls,
      scenarioCalls: commandHandlers.runMessageContent.mock.calls,
    }).toStrictEqual({
      doctorCalls: [],
      runCalls: [[signal]],
      scenarioCalls: [],
    });

    await executeCommand(
      ['run', 'message-content', '--json'],
      signal,
      commandHandlers,
    );
    expect(commandHandlers.runMessageContent).toHaveBeenCalledWith(signal);

    await executeCommand(
      ['run', 'categorization', '--json'],
      signal,
      commandHandlers,
    );
    expect(commandHandlers.runCategorization).toHaveBeenCalledWith(signal);

    await executeCommand(
      ['run', 'incremental-arrival', '--json'],
      signal,
      commandHandlers,
    );
    expect(commandHandlers.runIncrementalArrival).toHaveBeenCalledWith(signal);

    await executeCommand(['doctor'], signal, commandHandlers);
    expect(commandHandlers.doctor).toHaveBeenCalledWith();
  });

  it('delegates readiness inspection and enforcement', async () => {
    expect.assertions(2);
    const { signal } = new AbortController();
    const commandHandlers = handlers();

    await executeCommand(
      ['readiness', 'inspect', '--json'],
      signal,
      commandHandlers,
    );
    expect(commandHandlers.readinessInspect).toHaveBeenCalledWith();

    await executeCommand(
      ['readiness', 'require-ready', '--json'],
      signal,
      commandHandlers,
    );
    expect(commandHandlers.readinessRequireReady).toHaveBeenCalledWith();
  });

  it('delegates each manual sandbox command', async () => {
    expect.assertions(5);
    const { signal } = new AbortController();
    const commandHandlers = handlers();

    await executeCommand(
      ['sandbox', 'start', '--scenario', 'core-mail-loop'],
      signal,
      commandHandlers,
    );
    expect(commandHandlers.sandboxStart).toHaveBeenCalledWith(signal);
    await executeCommand(['sandbox', 'status'], signal, commandHandlers);
    expect(commandHandlers.sandboxStatus).toHaveBeenCalledWith(signal);
    await executeCommand(['sandbox', 'inject'], signal, commandHandlers);
    expect(commandHandlers.sandboxInject).toHaveBeenCalledWith(signal);
    await executeCommand(['sandbox', 'reset'], signal, commandHandlers);
    expect(commandHandlers.sandboxReset).toHaveBeenCalledWith(signal);
    await executeCommand(['sandbox', 'stop'], signal, commandHandlers);
    expect(commandHandlers.sandboxStop).toHaveBeenCalledWith();
  });

  it.each([
    ['run', 'core-mail-loop'],
    ['run', 'core-mail-loop', '--json', '--json'],
    ['run', 'core-mail-loop', '--unsupported'],
    ['run', 'message-content'],
    ['run', 'message-content', '--json', '--json'],
    ['run', 'message-content', '--unsupported'],
    ['run', 'incremental-arrival'],
    ['run', 'incremental-arrival', '--unsupported'],
    ['doctor', '--json'],
    ['readiness', 'inspect'],
    ['readiness', 'unknown', '--json'],
    ['sandbox', 'start'],
    ['sandbox', 'start', '--scenario', 'unknown'],
    ['sandbox', 'status', '--json'],
    ['sandbox', 'unknown'],
    ['unknown'],
  ])('rejects invalid arguments: %j', async (...args) => {
    expect.assertions(2);
    const commandHandlers = handlers();

    await expect(
      executeCommand(args, new AbortController().signal, commandHandlers),
    ).rejects.toThrow(USAGE);
    expect(
      Object.values(commandHandlers).map(
        (handler) => handler.mock.calls.length,
      ),
    ).toStrictEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  });
});
