import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { env as inheritedEnv } from 'node:process';
import { fileURLToPath } from 'node:url';
import { parseEnv } from 'node:util';

// Load only release configuration; unrelated backend secrets stay out of builds.
const file = path.join(import.meta.dirname, '..', '.env.local');
const local = existsSync(file) ? parseEnv(readFileSync(file, 'utf8')) : {};
const env = { ...inheritedEnv, UNWIRED_TESTFLIGHT_ENV_LOADED: '1' };
for (const name of [
  'ASC_KEY_ID',
  'ASC_ISSUER_ID',
  'ASC_KEY_PATH',
  'APPLE_DEVELOPMENT_TEAM',
  'UNWIRED_DEVELOPMENT_TEAM',
  'UNWIRED_GOOGLE_CLIENT_ID',
  'UNWIRED_CONVEX_URL',
  'UNWIRED_MOCK_SCENARIO',
]) {
  if (env[name] === undefined && local[name] !== undefined) {
    env[name] = local[name];
  }
}
delete env.ASC_PRIVATE_KEY;
const result = spawnSync(
  '/bin/zsh',
  [
    fileURLToPath(new URL('testflight.zsh', import.meta.url)),
    ...process.argv.slice(2),
  ],
  { env, stdio: 'inherit' },
);
if (result.error) {
  throw result.error;
}
process.exitCode = result.status ?? 1;
