export interface CommandHandlers {
  doctor: () => Promise<void>;
  runCoreMailLoop: (signal: AbortSignal) => Promise<void>;
  sandboxInject: (signal: AbortSignal) => Promise<void>;
  sandboxReset: (signal: AbortSignal) => Promise<void>;
  sandboxStart: (signal: AbortSignal) => Promise<void>;
  sandboxStatus: () => Promise<void>;
  sandboxStop: () => Promise<void>;
}

const USAGE =
  'Usage: pnpm mail:test run core-mail-loop --json | pnpm mail:test doctor | pnpm mail:test sandbox <start --scenario core-mail-loop|status|inject|reset|stop>';

export async function executeCommand(
  args: readonly string[],
  signal: AbortSignal,
  handlers: Readonly<CommandHandlers>,
): Promise<void> {
  if (isCoreMailLoopCommand(args)) {
    await handlers.runCoreMailLoop(signal);
    return;
  }
  if (isDoctorCommand(args)) {
    await handlers.doctor();
    return;
  }
  if (isSandboxStartCommand(args)) {
    await handlers.sandboxStart(signal);
    return;
  }
  if (isSandboxCommand(args, 'status')) {
    await handlers.sandboxStatus();
    return;
  }
  if (isSandboxCommand(args, 'inject')) {
    await handlers.sandboxInject(signal);
    return;
  }
  if (isSandboxCommand(args, 'reset')) {
    await handlers.sandboxReset(signal);
    return;
  }
  if (isSandboxCommand(args, 'stop')) {
    await handlers.sandboxStop();
    return;
  }
  throw new Error(USAGE);
}

function isCoreMailLoopCommand(args: readonly string[]): boolean {
  return (
    args.length === 3 &&
    args[0] === 'run' &&
    args[1] === 'core-mail-loop' &&
    args[2] === '--json'
  );
}

function isDoctorCommand(args: readonly string[]): boolean {
  return args.length === 1 && args[0] === 'doctor';
}

function isSandboxStartCommand(args: readonly string[]): boolean {
  return (
    args.length === 4 &&
    args[0] === 'sandbox' &&
    args[1] === 'start' &&
    args[2] === '--scenario' &&
    args[3] === 'core-mail-loop'
  );
}

function isSandboxCommand(
  args: readonly string[],
  action: 'inject' | 'reset' | 'status' | 'stop',
): boolean {
  return args.length === 2 && args[0] === 'sandbox' && args[1] === action;
}
