import { runCommand } from '../src/process.ts';

describe('command diagnostics', () => {
  it('reports stdout and stderr when a command fails', async () => {
    expect.assertions(1);

    await expect(
      runCommand(process.execPath, [
        '-e',
        "process.stdout.write('build output'); process.stderr.write('failure detail'); process.exit(2)",
      ]),
    ).rejects.toThrow(/build output[\s\S]*failure detail/u);
  });
});
