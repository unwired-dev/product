import type { ChildProcess } from 'node:child_process';

import { spawn } from 'node:child_process';

export interface CommandResult {
  stderr: string;
  stdout: string;
}

export async function runCommand(
  command: string,
  arguments_: readonly string[],
  options: { env?: NodeJS.ProcessEnv; signal?: AbortSignal } = {},
): Promise<CommandResult> {
  const child = spawn(command, arguments_, {
    env: options.env,
    signal: options.signal,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const stdout: Buffer[] = [];
  const stderr: Buffer[] = [];
  child.stdout.on('data', (chunk: Buffer) => {
    stdout.push(chunk);
  });
  child.stderr.on('data', (chunk: Buffer) => {
    stderr.push(chunk);
  });
  const exitCode = await waitForExit(child);
  const result = {
    stderr: Buffer.concat(stderr).toString('utf8'),
    stdout: Buffer.concat(stdout).toString('utf8'),
  };
  if (exitCode !== 0) {
    throw new Error(
      `${command} exited with status ${String(exitCode)}: ${result.stderr.trim()}`,
    );
  }
  return result;
}

export function waitForExit(child: ChildProcess): Promise<number | null> {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve(child.exitCode);
  }
  return new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', resolve);
  });
}
