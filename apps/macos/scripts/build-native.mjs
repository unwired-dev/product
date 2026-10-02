import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const result = spawnSync(
  '/bin/zsh',
  [
    fileURLToPath(new URL('build-native.zsh', import.meta.url)),
    ...process.argv.slice(2),
  ],
  { stdio: 'inherit' },
);
if (result.error) {
  throw result.error;
}
process.exitCode = result.status ?? 1;
