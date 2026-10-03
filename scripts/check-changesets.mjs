// Changesets rejects a pending changeset for a package outside the workspace only
// when versioning, which blocks every release. Fail the pull request instead.
import { readdirSync, readFileSync } from 'node:fs';
import { parse } from 'node:path';

const root = new URL('../', import.meta.url);
const manifest = (directory) =>
  JSON.parse(readFileSync(new URL(`${directory}/package.json`, root), 'utf8'));
// Workspace members are the direct children of apps/ and packages/ that have a manifest.
const packages = new Set(
  ['apps', 'packages'].flatMap((group) =>
    readdirSync(new URL(group, root), { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .flatMap((entry) => {
        try {
          return [manifest(`${group}/${entry.name}`).name];
        } catch {
          return [];
        }
      }),
  ),
);
const failures = [];
for (const file of readdirSync(new URL('.changeset', root))) {
  if (parse(file).ext !== '.md' || file === 'README.md') continue;
  const text = readFileSync(new URL(`.changeset/${file}`, root), 'utf8');
  const header = /^---\r?\n(?<targets>[\s\S]*?)\r?\n?---/u.exec(text);
  if (!header) {
    failures.push(`${file}: missing changeset header`);
    continue;
  }
  for (const line of header.groups.targets.split(/\r?\n/u)) {
    const target = /^['"]?(?<name>[^'":]+)['"]?\s*:/u.exec(line.trim());
    if (target && !packages.has(target.groups.name)) {
      failures.push(
        `${file}: ${target.groups.name} is not a workspace package`,
      );
    }
  }
}
if (failures.length > 0) {
  console.error(failures.join('\n'));
  process.exitCode = 1;
}
