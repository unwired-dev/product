export interface CommandHandlers {
  doctor: () => Promise<void>;
  runCategorization: (signal: AbortSignal) => Promise<void>;
  runCoreMailLoop: (signal: AbortSignal) => Promise<void>;
}

const USAGE =
  'Usage: pnpm mail:test run <core-mail-loop|categorization> --json | pnpm mail:test doctor';

export async function executeCommand(
  args: readonly string[],
  signal: AbortSignal,
  handlers: Readonly<CommandHandlers>,
): Promise<void> {
  if (isRunCommand(args, 'core-mail-loop')) {
    await handlers.runCoreMailLoop(signal);
    return;
  }
  if (isRunCommand(args, 'categorization')) {
    await handlers.runCategorization(signal);
    return;
  }
  if (isDoctorCommand(args)) {
    await handlers.doctor();
    return;
  }
  throw new Error(USAGE);
}

function isRunCommand(
  args: readonly string[],
  scenario: 'categorization' | 'core-mail-loop',
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
