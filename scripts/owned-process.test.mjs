import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import {
  existsSync,
  mkdirSync,
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
  const unrelated = setup(t).shell;
  const sleep = await child(shell.pid);
  assert.equal(owned('record', ledger, String(shell.pid)).status, 0);
  const result = owned('stop', ledger);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(running(sleep), false);
  assert.equal(running(unrelated.pid), true);
  assert.equal(existsSync(ledger), false);
  assert.equal(owned('stop', ledger).status, 0);
});

for (const [field, index] of [
  ['working directory', 1],
  ['start time', 2],
  ['command', 3],
]) {
  test(`stop leaves a PID and its descendants running when its ${field} differs`, async (t) => {
    const { ledger, shell } = setup(t);
    const sleep = await child(shell.pid);
    assert.equal(owned('record', ledger, String(shell.pid)).status, 0);
    const fields = readFileSync(ledger, 'utf8').trimEnd().split('\t');
    fields[index] = 'no longer matches';
    writeFileSync(ledger, `${fields.join('\t')}\n`);
    const result = owned('stop', ledger);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /no longer the recorded process/u);
    assert.equal(running(shell.pid), true);
    assert.equal(running(sleep), true);
    assert.equal(existsSync(ledger), true);
  });
}

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

// Substitute process inspection to exercise PID reuse and inaccessible cwd
// without ever assigning a real unrelated PID to a kill target.
function inspected(directory, body) {
  const lsof = spawnSync('sh', ['-c', 'command -v lsof'], {
    encoding: 'utf8',
  }).stdout.trim();
  const bin = path.join(directory, 'bin');
  mkdirSync(bin);
  writeFileSync(
    path.join(bin, 'lsof'),
    `#!${process.execPath}
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
const directory = ${JSON.stringify(directory)};
${body}
const result = spawnSync(${JSON.stringify(lsof)}, process.argv.slice(2), { stdio: 'inherit' });
process.exit(result.status ?? 1);
`,
    { mode: 0o755 },
  );
  return (...args) =>
    spawnSync(script, args, {
      encoding: 'utf8',
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
    });
}

async function resistant(t, directory) {
  const marker = path.join(directory, 'terminated');
  const fixture = spawn(
    process.execPath,
    [
      '-e',
      `
    const fs = require('node:fs');
    process.on('SIGTERM', () => fs.writeFileSync(${JSON.stringify(marker)}, 'term'));
    setInterval(() => {}, 1000);
    console.log('ready');
  `,
    ],
    { stdio: ['ignore', 'pipe', 'ignore'] },
  );
  t.after(() => fixture.kill('SIGKILL'));
  await once(fixture.stdout, 'data');
  return fixture;
}

for (const phase of ['before TERM', 'before KILL']) {
  test(`stop rechecks identity ${phase} and retains the ledger on mismatch`, async (t) => {
    const { ledger } = setup(t);
    const directory = path.dirname(ledger);
    const fixture = await resistant(t, directory);
    assert.equal(owned('record', ledger, String(fixture.pid)).status, 0);
    const invoke = inspected(
      directory,
      `
if (process.argv.at(-1) === ${JSON.stringify(String(fixture.pid))}) {
  const countPath = directory + '/inspections';
  const count = fs.existsSync(countPath) ? Number(fs.readFileSync(countPath, 'utf8')) + 1 : 1;
  fs.writeFileSync(countPath, String(count));
  if (${phase === 'before TERM' ? 'count > 1' : "fs.existsSync(directory + '/terminated')"}) {
    console.log('n/a/different/cwd');
    process.exit(0);
  }
}
`,
    );
    const result = invoke('stop', ledger);
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stderr, /no longer the recorded process/u);
    assert.equal(running(fixture.pid), true);
    assert.equal(existsSync(ledger), true);
    assert.equal(
      existsSync(path.join(directory, 'terminated')),
      phase === 'before KILL',
    );
  });
}

test('failed cwd inspection retains ownership while other recorded processes are cleaned', async (t) => {
  const { ledger, shell } = setup(t);
  const other = setup(t).shell;
  await child(shell.pid);
  await child(other.pid);
  assert.equal(owned('record', ledger, String(shell.pid)).status, 0);
  assert.equal(owned('record', ledger, String(other.pid)).status, 0);
  const invoke = inspected(
    path.dirname(ledger),
    `
if (process.argv.at(-1) === ${JSON.stringify(String(shell.pid))}) process.exit(1);
`,
  );
  const result = invoke('stop', ledger);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /cannot be verified/u);
  assert.equal(running(shell.pid), true);
  await once(other, 'exit', { signal: AbortSignal.timeout(2000) });
  assert.equal(running(other.pid), false);
  assert.equal(existsSync(ledger), true);
});

test('malformed ledger fails before signaling and an empty ledger is safe', async (t) => {
  const { ledger, shell } = setup(t);
  await child(shell.pid);
  assert.equal(owned('record', ledger, String(shell.pid)).status, 0);
  writeFileSync(
    ledger,
    `${readFileSync(ledger, 'utf8')}0\t/\tstart\tcommand\n`,
  );
  const result = owned('stop', ledger);
  assert.equal(result.status, 2, result.stderr);
  assert.match(result.stderr, /malformed ledger/u);
  assert.equal(running(shell.pid), true);
  assert.equal(existsSync(ledger), true);
  writeFileSync(ledger, '');
  assert.equal(owned('stop', ledger).status, 0);
  assert.equal(existsSync(ledger), false);
});

test('stop escalates a still-matching process that ignores TERM and confirms its exit', async (t) => {
  const { ledger } = setup(t);
  const fixture = await resistant(t, path.dirname(ledger));
  assert.equal(owned('record', ledger, String(fixture.pid)).status, 0);
  const result = owned('stop', ledger);
  assert.equal(result.status, 0, result.stderr);
  await once(fixture, 'exit', { signal: AbortSignal.timeout(2000) });
  assert.equal(running(fixture.pid), false);
  assert.equal(existsSync(ledger), false);
});

test('failed descendant enumeration preserves the ledger and leaves the tree running', async (t) => {
  const { ledger, shell } = setup(t);
  const sleep = await child(shell.pid);
  assert.equal(owned('record', ledger, String(shell.pid)).status, 0);
  const directory = path.dirname(ledger);
  const invoke = inspected(directory, '');
  writeFileSync(path.join(directory, 'bin/pgrep'), '#!/bin/sh\nexit 2\n', {
    mode: 0o755,
  });
  const result = invoke('stop', ledger);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /cannot enumerate descendants/u);
  assert.equal(running(shell.pid), true);
  assert.equal(running(sleep), true);
  assert.equal(existsSync(ledger), true);
});
