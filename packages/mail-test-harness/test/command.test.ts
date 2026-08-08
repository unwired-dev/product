import { executeCommand } from '../src/command.ts';

describe('mail test command dispatch', () => {
  it('delegates valid commands to the matching handler', async () => {
    expect.assertions(2);
    const { signal } = new AbortController();
    const handlers = {
      doctor: vi.fn<() => Promise<void>>(async () => undefined),
      runCoreMailLoop: vi.fn<(signal: AbortSignal) => Promise<void>>(
        async () => undefined,
      ),
    };

    await executeCommand(['run', 'core-mail-loop', '--json'], signal, handlers);
    expect({
      doctorCalls: handlers.doctor.mock.calls,
      runCalls: handlers.runCoreMailLoop.mock.calls,
    }).toStrictEqual({ doctorCalls: [], runCalls: [[signal]] });

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
    ['doctor', '--json'],
    ['unknown'],
  ])('rejects invalid arguments: %j', async (...args) => {
    expect.assertions(1);
    const handlers = {
      doctor: vi.fn<() => Promise<void>>(async () => undefined),
      runCoreMailLoop: vi.fn<(signal: AbortSignal) => Promise<void>>(
        async () => undefined,
      ),
    };

    await expect(
      executeCommand(args, new AbortController().signal, handlers),
    ).rejects.toThrow(
      'Usage: pnpm mail:test run core-mail-loop --json | pnpm mail:test doctor',
    );
  });
});
