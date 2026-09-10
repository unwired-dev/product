import { execFileSync } from 'node:child_process';
import { readFile, writeFile, access } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';

const root = '/Users/jansilhan/git/github/product';
const directory = '/tmp/unwired-doc-pr.jiAr1X';
const worktree = `${directory}/worktree`;
const git = (...args) => execFileSync('git', ['-C', worktree, ...args], { encoding: 'utf8' });
const names = new Set([...git('diff', '--name-only', '-z').split('\0'), ...git('ls-files', '--others', '--exclude-standard', '-z').split('\0')].filter(Boolean));
const existing = [];
for (const path of names) {
  if (!path.endsWith('.md') || path.startsWith('.agents/')) throw new Error(`Unexpected PR path ${path}`);
  try {
    const actual = await readFile(`${worktree}/${path}`, 'utf8');
    const source = await readFile(`${root}/${path}`, 'utf8');
    if (actual !== source) throw new Error(`Copy differs from reviewed working tree: ${path}`);
    existing.push(path);
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
}
execFileSync('pnpm', ['--filter', '@private-email/contracts', 'exec', 'oxfmt', '--config', `${root}/oxfmt.config.ts`, '--disable-nested-config', '--check', ...existing.map((path) => `${worktree}/${path}`)], { cwd: root, stdio: 'inherit' });
let links = 0;
for (const path of existing) {
  const body = await readFile(`${worktree}/${path}`, 'utf8');
  for (const match of body.replace(/```[\s\S]*?```/gu, '').matchAll(/\[[^\]]*\]\(([^\s)]+)\)/gu)) {
    if (/^[a-z][a-z\d+.-]*:/iu.test(match[1])) continue;
    const [part, hash] = match[1].split('#');
    const destination = part ? resolve(worktree, dirname(path), decodeURI(part)) : resolve(worktree, path);
    await access(destination);
    if (hash && destination.endsWith('.md')) {
      const contents = await readFile(destination, 'utf8');
      const anchors = [...contents.matchAll(/^#{1,6} (.+)$/gmu)].map((item) => item[1].toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s/gu, '-'));
      if (!anchors.includes(decodeURIComponent(hash))) throw new Error(`Missing heading ${path}: ${match[1]}`);
    }
    links++;
  }
}
const oldGuide = git('show', 'origin/main:AGENTS.md');
const newGuide = await readFile(`${worktree}/docs/agents/apple-validation.md`, 'utf8');
const commands = [...oldGuide.matchAll(/```sh\n(xcodebuild[\s\S]*?)```/gu)];
for (const [, command] of commands) if (!newGuide.includes(command)) throw new Error('Required Xcode command changed');
git('diff', '--check');
const report = { documents: existing.length, localLinks: links, preservedXcodeBlocks: commands.length, changedPaths: [...names], worktree, status: 'passed' };
await writeFile(`${directory}/validation.json`, JSON.stringify(report, null, 2) + '\n');
await writeFile(`${directory}/pr-body.md`, `Records the approved Gmail-first Expo and native React Native Mac rewrite, its architecture decisions, and the 78-ticket implementation map. Archives seven prototype plans, separates current Swift maintenance guidance, and simplifies the root agent guide to 50 lines.\n\nPreparation for #592 and #627. Native version-27 qualification remains deferred under #623.\n\nValidation: Oxfmt passed for ${existing.length} changed documents; ${links} local documentation links and all ${commands.length} existing Xcode command blocks were verified. Whitespace checks passed. This is documentation-only; runtime tests were not needed.\n`);
process.stdout.write(`Verified ${existing.length} documents, ${links} local links, and ${commands.length} preserved Xcode command blocks.\n`);
