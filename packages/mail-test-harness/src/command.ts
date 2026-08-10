export interface CommandHandlers {
  doctor: () => Promise<void>;
  runCoreMailLoop: (signal: AbortSignal) => Promise<void>;
  runMessageContent: (signal: AbortSignal) => Promise<void>;
}

const USAGE =
  'Usage: pnpm mail:test run <core-mail-loop|message-content> --json | pnpm mail:test doctor';

export async function executeCommand(
  args: readonly string[],
  signal: AbortSignal,
  handlers: Readonly<CommandHandlers>,
): Promise<void> {
  if (isCoreMailLoopCommand(args)) {
    await handlers.runCoreMailLoop(signal);
    return;
  }
  if (isMessageContentCommand(args)) {
    await handlers.runMessageContent(signal);
    return;
  }
  if (isDoctorCommand(args)) {
    await handlers.doctor();
    return;
  }
  throw new Error(USAGE);
}

function isMessageContentCommand(args: readonly string[]): boolean {
  return (
    args.length === 3 &&
    args[0] === 'run' &&
    args[1] === 'message-content' &&
    args[2] === '--json'
  );
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
