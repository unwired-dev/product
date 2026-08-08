export interface CommandHandlers {
  doctor: () => Promise<void>;
  runCoreMailLoop: (signal: AbortSignal) => Promise<void>;
}

const USAGE =
  'Usage: pnpm mail:test run core-mail-loop --json | pnpm mail:test doctor';

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
