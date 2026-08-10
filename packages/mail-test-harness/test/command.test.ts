import { executeCommand } from '../src/command.ts';

describe('mail test command dispatch', () => {
  it('delegates valid commands to the matching handler', async () => {
    expect.assertions(3);
    const { signal } = new AbortController();
    const handlers = {
      doctor: vi.fn<() => Promise<void>>(async () => undefined),
      runCoreMailLoop: vi.fn<(signal: AbortSignal) => Promise<void>>(
        async () => undefined,
      ),
      runMessageContent: vi.fn<(signal: AbortSignal) => Promise<void>>(
        async () => undefined,
      ),
    };

    await executeCommand(['run', 'core-mail-loop', '--json'], signal, handlers);
    expect({
      doctorCalls: handlers.doctor.mock.calls,
      runCalls: handlers.runCoreMailLoop.mock.calls,
      scenarioCalls: handlers.runMessageContent.mock.calls,
    }).toStrictEqual({
      doctorCalls: [],
      runCalls: [[signal]],
      scenarioCalls: [],
    });

    await executeCommand(
      ['run', 'message-content', '--json'],
      signal,
      handlers,
    );
    expect(handlers.runMessageContent).toHaveBeenCalledWith(signal);

    await executeCommand(['doctor'], signal, handlers);
    expect({
      doctorCalls: handlers.doctor.mock.calls,
      runCalls: handlers.runCoreMailLoop.mock.calls,
    }).toStrictEqual({ doctorCalls: [[]], runCalls: [[signal]] });
  });

  it.each([
    ['run', 'core-mail-loop'],
    ['run', 'core-mail-loop', '--json', '--json'],
    ['run', 'core-mail-loop', '--unsupported'],
    ['run', 'message-content'],
    ['run', 'message-content', '--json', '--json'],
    ['run', 'message-content', '--unsupported'],
    ['doctor', '--json'],
    ['unknown'],
  ])('rejects invalid arguments: %j', async (...args) => {
    expect.assertions(2);
    const handlers = {
      doctor: vi.fn<() => Promise<void>>(async () => undefined),
      runCoreMailLoop: vi.fn<(signal: AbortSignal) => Promise<void>>(
        async () => undefined,
      ),
      runMessageContent: vi.fn<(signal: AbortSignal) => Promise<void>>(
        async () => undefined,
      ),
    };

    await expect(
      executeCommand(args, new AbortController().signal, handlers),
    ).rejects.toThrow(
      'Usage: pnpm mail:test run <core-mail-loop|message-content> --json | pnpm mail:test doctor',
    );
    expect({
      doctorCalls: handlers.doctor.mock.calls,
      runCalls: handlers.runCoreMailLoop.mock.calls,
      scenarioCalls: handlers.runMessageContent.mock.calls,
    }).toStrictEqual({ doctorCalls: [], runCalls: [], scenarioCalls: [] });
  });
});
