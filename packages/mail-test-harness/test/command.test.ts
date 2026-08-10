import { executeCommand } from '../src/command.ts';

describe('mail test command dispatch', () => {
  it('delegates valid commands to the matching handler', async () => {
    expect.assertions(3);
    const { signal } = new AbortController();
    const handlers = {
      doctor: vi.fn<() => Promise<void>>(async () => undefined),
      runCategorization: vi.fn<(signal: AbortSignal) => Promise<void>>(
        async () => undefined,
      ),
      runCoreMailLoop: vi.fn<(signal: AbortSignal) => Promise<void>>(
        async () => undefined,
      ),
    };

    await executeCommand(['run', 'core-mail-loop', '--json'], signal, handlers);
    expect({
      doctorCalls: handlers.doctor.mock.calls,
      categorizationCalls: handlers.runCategorization.mock.calls,
      runCalls: handlers.runCoreMailLoop.mock.calls,
    }).toStrictEqual({
      categorizationCalls: [],
      doctorCalls: [],
      runCalls: [[signal]],
    });

    await executeCommand(['run', 'categorization', '--json'], signal, handlers);
    expect(handlers.runCategorization).toHaveBeenCalledWith(signal);

    await executeCommand(['doctor'], signal, handlers);
    expect({
      doctorCalls: handlers.doctor.mock.calls,
      categorizationCalls: handlers.runCategorization.mock.calls,
      runCalls: handlers.runCoreMailLoop.mock.calls,
    }).toStrictEqual({
      categorizationCalls: [[signal]],
      doctorCalls: [[]],
      runCalls: [[signal]],
    });
  });

  it.each([
    ['run', 'core-mail-loop'],
    ['run', 'core-mail-loop', '--json', '--json'],
    ['run', 'core-mail-loop', '--unsupported'],
    ['doctor', '--json'],
    ['unknown'],
  ])('rejects invalid arguments: %j', async (...args) => {
    expect.assertions(2);
    const handlers = {
      doctor: vi.fn<() => Promise<void>>(async () => undefined),
      runCategorization: vi.fn<(signal: AbortSignal) => Promise<void>>(
        async () => undefined,
      ),
      runCoreMailLoop: vi.fn<(signal: AbortSignal) => Promise<void>>(
        async () => undefined,
      ),
    };

    await expect(
      executeCommand(args, new AbortController().signal, handlers),
    ).rejects.toThrow(
      'Usage: pnpm mail:test run <core-mail-loop|categorization> --json | pnpm mail:test doctor',
    );
    expect({
      doctorCalls: handlers.doctor.mock.calls,
      categorizationCalls: handlers.runCategorization.mock.calls,
      runCalls: handlers.runCoreMailLoop.mock.calls,
    }).toStrictEqual({
      categorizationCalls: [],
      doctorCalls: [],
      runCalls: [],
    });
  });
});
