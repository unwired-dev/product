import { runCoreMailLoopSmoke } from './harness.ts';
import { inspectOwnedRuns } from './ownership.ts';

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const abortController = new AbortController();
  const cancel = (): void => {
    abortController.abort();
  };
  process.once('SIGINT', cancel);
  process.once('SIGTERM', cancel);

  try {
    await executeCommand(args, abortController.signal);
  } finally {
    process.off('SIGINT', cancel);
    process.off('SIGTERM', cancel);
  }
}

async function executeCommand(
  args: readonly string[],
  signal: AbortSignal,
): Promise<void> {
  if (args[0] === 'run' && args[1] === 'core-mail-loop') {
    await runCoreMailLoop(args, signal);
    return;
  }
  if (args[0] === 'doctor' && args.length === 1) {
    await runDoctor();
    return;
  }
  throw new Error(
    'Usage: pnpm mail:test run core-mail-loop --json | pnpm mail:test doctor',
  );
}

async function runCoreMailLoop(
  args: readonly string[],
  signal: AbortSignal,
): Promise<void> {
  const unsupported = args.slice(2).filter((argument) => argument !== '--json');
  if (unsupported.length > 0) {
    throw new Error(`Unsupported argument: ${unsupported[0]}`);
  }
  const evidence = await runCoreMailLoopSmoke(signal);
  process.stdout.write(`${JSON.stringify(evidence)}\n`);
}

async function runDoctor(): Promise<void> {
  const findings = await inspectOwnedRuns();
  process.stdout.write(
    `${JSON.stringify({ findings, kind: 'mail-test-doctor', schemaVersion: 1, status: 'completed' })}\n`,
  );
}

try {
  await main();
} catch (error: unknown) {
  const message =
    error instanceof Error
      ? error.message
      : 'Unknown Mail Test Harness failure.';
  process.stderr.write(`Mail Test Harness failed: ${message}\n`);
  process.stdout.write(
    `${JSON.stringify({ error: 'mail-test-failed', kind: 'mail-test-evidence', schemaVersion: 1, status: 'failed' })}\n`,
  );
  process.exitCode = 1;
}
