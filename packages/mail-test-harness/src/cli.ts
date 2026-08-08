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
    if (args[0] === 'run' && args[1] === 'core-mail-loop') {
      const unsupported = args
        .slice(2)
        .filter((argument) => argument !== '--json');
      if (unsupported.length > 0) {
        throw new Error(`Unsupported argument: ${unsupported[0]}`);
      }
      const evidence = await runCoreMailLoopSmoke(abortController.signal);
      process.stdout.write(`${JSON.stringify(evidence)}\n`);
    } else if (args[0] === 'doctor' && args.length === 1) {
      const findings = await inspectOwnedRuns();
      process.stdout.write(
        `${JSON.stringify({ findings, kind: 'mail-test-doctor', schemaVersion: 1, status: 'completed' })}\n`,
      );
    } else {
      throw new Error(
        'Usage: pnpm mail:test run core-mail-loop --json | pnpm mail:test doctor',
      );
    }
  } finally {
    process.off('SIGINT', cancel);
    process.off('SIGTERM', cancel);
  }
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
