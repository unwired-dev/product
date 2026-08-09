import { executeCommand } from './command.ts';
import { runCoreMailLoopSmoke } from './harness.ts';
import { inspectOwnedRuns } from './ownership.ts';
import {
  injectManualSandbox,
  resetManualSandbox,
  startManualSandbox,
  statusManualSandbox,
  stopManualSandbox,
} from './sandbox.ts';

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const abortController = new AbortController();
  const cancel = (): void => {
    abortController.abort();
  };
  process.once('SIGINT', cancel);
  process.once('SIGTERM', cancel);

  try {
    await executeCommand(args, abortController.signal, {
      doctor: runDoctor,
      runCoreMailLoop,
      sandboxInject: async (signal) => {
        writeResult(await injectManualSandbox(signal));
      },
      sandboxReset: async (signal) => {
        writeResult(await resetManualSandbox(signal));
      },
      sandboxStart: async (signal) => {
        writeResult(await startManualSandbox(signal));
      },
      sandboxStatus: async () => {
        writeResult(await statusManualSandbox());
      },
      sandboxStop: async () => {
        writeResult(await stopManualSandbox());
      },
    });
  } finally {
    process.off('SIGINT', cancel);
    process.off('SIGTERM', cancel);
  }
}

async function runCoreMailLoop(signal: AbortSignal): Promise<void> {
  const evidence = await runCoreMailLoopSmoke(signal);
  process.stdout.write(`${JSON.stringify(evidence)}\n`);
}

async function runDoctor(): Promise<void> {
  const findings = await inspectOwnedRuns();
  process.stdout.write(
    `${JSON.stringify({ findings, kind: 'mail-test-doctor', schemaVersion: 1, status: 'completed' })}\n`,
  );
}

function writeResult(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value)}\n`);
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
