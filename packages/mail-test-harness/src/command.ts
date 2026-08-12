export interface CommandHandlers {
  doctor: () => Promise<void>;
  runCategorization: (signal: AbortSignal) => Promise<void>;
  runCoreMailLoop: (
    signal: AbortSignal,
    options: Readonly<RunCoreMailLoopOptions>,
  ) => Promise<void>;
  runIncrementalArrival: (signal: AbortSignal) => Promise<void>;
  runMessageContent: (signal: AbortSignal) => Promise<void>;
  sandboxInject: (signal: AbortSignal) => Promise<void>;
  sandboxReset: (signal: AbortSignal) => Promise<void>;
  sandboxStart: (signal: AbortSignal) => Promise<void>;
  sandboxStatus: (signal: AbortSignal) => Promise<void>;
  sandboxStop: () => Promise<void>;
}

export interface RunCoreMailLoopOptions {
  resultBundleDirectory?: string;
}

const USAGE =
  'Usage: pnpm mail:test run core-mail-loop --json [--result-bundle-directory <path>] | pnpm mail:test run <categorization|incremental-arrival|message-content> --json | pnpm mail:test doctor | pnpm mail:test sandbox <start --scenario core-mail-loop|status|inject|reset|stop>';

export async function executeCommand(
  args: readonly string[],
  signal: AbortSignal,
  handlers: Readonly<CommandHandlers>,
): Promise<void> {
  const coreMailLoopOptions = parseCoreMailLoopOptions(args);
  if (coreMailLoopOptions !== undefined) {
    await handlers.runCoreMailLoop(signal, coreMailLoopOptions);
    return;
  }
  if (isRunCommand(args, 'categorization')) {
    await handlers.runCategorization(signal);
    return;
  }
  if (isRunCommand(args, 'incremental-arrival')) {
    await handlers.runIncrementalArrival(signal);
    return;
  }
  if (isRunCommand(args, 'message-content')) {
    await handlers.runMessageContent(signal);
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
    await handlers.sandboxStatus(signal);
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

function parseCoreMailLoopOptions(
  args: readonly string[],
): RunCoreMailLoopOptions | undefined {
  if (isRunCommand(args, 'core-mail-loop')) {
    return {};
  }
  if (
    args.length === 5 &&
    args[0] === 'run' &&
    args[1] === 'core-mail-loop' &&
    args[2] === '--json' &&
    args[3] === '--result-bundle-directory' &&
    args[4] !== undefined &&
    args[4].length > 0
  ) {
    return { resultBundleDirectory: args[4] };
  }
  return undefined;
}

function isRunCommand(
  args: readonly string[],
  scenario:
    | 'categorization'
    | 'core-mail-loop'
    | 'incremental-arrival'
    | 'message-content',
): boolean {
  return (
    args.length === 3 &&
    args[0] === 'run' &&
    args[1] === scenario &&
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
