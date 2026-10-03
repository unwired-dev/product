// Changesets rejects a pending changeset for a package outside the workspace only
// when versioning, which blocks every release. Fail the pull request instead.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const root = new URL('../', import.meta.url);
// Resolve the installed CLI's own workspace reader and parser so this gate uses
// exactly the same workspace globs and frontmatter semantics as versioning.
const require = createRequire(import.meta.url);
const cliRequire = createRequire(
  require.resolve('@changesets/cli/package.json'),
);
const { getPackagesSync } = cliRequire('@manypkg/get-packages');
const readRequire = createRequire(cliRequire.resolve('@changesets/read'));
const { parseChangesetFile } = readRequire('@changesets/parse');
const packages = new Set(
  getPackagesSync(fileURLToPath(root)).packages.map(
    ({ packageJson }) => packageJson.name,
  ),
);
const failures = [];
// Versioning also reads prerelease changesets from .changeset/pre.
const pre = new URL('.changeset/pre/', root);
const files = [
  ...readdirSync(new URL('.changeset', root)),
  ...(existsSync(pre) ? readdirSync(pre).map((file) => `pre/${file}`) : []),
];
for (const file of files) {
  const name = file.replace(/^pre\//u, '');
  if (
    name.startsWith('.') ||
    !name.endsWith('.md') ||
    /^(?:readme|agents|claude|gemini)\.md$/iu.test(name)
  ) {
    continue;
  }
  const text = readFileSync(new URL(`.changeset/${file}`, root), 'utf8');
  try {
    for (const { name } of parseChangesetFile(text).releases) {
      if (!packages.has(name)) {
        failures.push(`${file}: ${name} is not a workspace package`);
      }
    }
  } catch (error) {
    failures.push(`${file}: ${error.message}`);
  }
}
if (failures.length > 0) {
  console.error(failures.join('\n'));
  process.exitCode = 1;
}
