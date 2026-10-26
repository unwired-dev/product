import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('owned-process', import.meta.url));
const owned = (...args) => spawnSync(script, args, { encoding: 'utf8' });
const running = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

function setup(t) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'owned-process-'));
  // The shell's sleep child stands in for a build's helper processes.
  const shell = spawn('sh', ['-c', 'sleep 60 & wait'], { stdio: 'ignore' });
  t.after(() => {
    spawnSync('pkill', ['-KILL', '-P', String(shell.pid)]);
    shell.kill('SIGKILL');
    rmSync(directory, { recursive: true, force: true });
  });
  return { ledger: path.join(directory, 'ledger.tsv'), shell };
}

const child = async (pid) => {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const found = spawnSync('pgrep', ['-P', String(pid)], {
      encoding: 'utf8',
    }).stdout.trim();
    if (found) {
      return Number(found);
    }
    await delay(20);
  }
  throw new Error('the fixture child did not start');
};

test('stop ends a recorded process and its descendants', async (t) => {
  const { ledger, shell } = setup(t);
  const sleep = await child(shell.pid);
  assert.equal(owned('record', ledger, String(shell.pid)).status, 0);
  const result = owned('stop', ledger);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(running(sleep), false);
  assert.equal(existsSync(ledger), false);
});

test('stop leaves a PID running when it no longer matches the record', async (t) => {
  const { ledger, shell } = setup(t);
  await child(shell.pid);
  assert.equal(owned('record', ledger, String(shell.pid)).status, 0);
  const [pid, cwd, , command] = readFileSync(ledger, 'utf8')
    .trimEnd()
    .split('\t');
  writeFileSync(
    ledger,
    `${pid}\t${cwd}\tMon Jan  1 00:00:00 2024\t${command}\n`,
  );
  const result = owned('stop', ledger);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /no longer the recorded process/u);
  assert.equal(running(shell.pid), true);
  assert.equal(existsSync(ledger), true);
});

test('record rejects anything but a running PID', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'owned-process-'));
  const ledger = path.join(directory, 'ledger.tsv');
  try {
    assert.equal(owned('record', ledger, 'xcodebuild').status, 2);
    assert.equal(owned('record', ledger, '99999999').status, 1);
    assert.equal(existsSync(ledger), false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
