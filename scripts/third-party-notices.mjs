import { spawnSync } from 'node:child_process';
// Bundle notices from the same installed dependency graphs as archive reports.
// Missing text remains visible; coverage is not a legal compatibility decision.
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

import * as Schema from 'effect/Schema';

const [map, pods, swift, destination] = process.argv.slice(2);
if (!destination) {
  throw new Error(
    'usage: third-party-notices.mjs <bundle.map> <Pods> <SourcePackages> <resources>',
  );
}
const decode = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);
const hash = (text) => createHash('sha256').update(text).digest('hex');
const inventory = (script, args) => {
  const result = spawnSync(
    process.execPath,
    [path.join(import.meta.dirname, script), ...args, '--include-text'],
    {
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
    },
  );
  if (result.status !== 0) {
    throw new Error(
      result.stderr.trim() === '' ? `failed ${script}` : result.stderr,
    );
  }
  return decode(result.stdout);
};
const npm = inventory('licence-inventory.mjs', [map]);
const native = inventory('native-licence-inventory.mjs', [pods, swift]);
const supplementRoot = path.join(import.meta.dirname, 'third-party-licences');
const manifest = path.join(supplementRoot, 'index.json');
const supplements = existsSync(manifest)
  ? decode(readFileSync(manifest, 'utf8'))
  : [];
const supplementKey = ({ ecosystem, name, version, revision }) =>
  `${ecosystem}:${name}@${ecosystem === 'swift' ? revision : version}`;
const grouped = Map.groupBy(supplements, supplementKey);
const requirementsMet = (entry) =>
  (entry.requires ?? []).every(
    (requirement) =>
      requirement.ecosystem === 'pod' &&
      native.pods.some(
        (pod) =>
          pod.name === requirement.name && pod.version === requirement.version,
      ),
  );
const readSupplement = (entry) => {
  const text = readFileSync(path.join(supplementRoot, entry.file), 'utf8');
  if (hash(text) !== entry.sha256) {
    throw new Error(`supplement hash mismatch: ${entry.file}`);
  }
  return { source: entry.url, text };
};
const vendors = new Set([
  'swift:swift-nio-ssl',
  'swift:swift-crypto',
  'pod:hermes-engine',
  'pod:ReactNativeDependencies',
]);
const coverageComplete = (identity, missingRoot, pinned) =>
  [
    !missingRoot || pinned.some((entry) => entry.role === 'root'),
    !vendors.has(identity) || pinned.some((entry) => entry.role === 'vendor'),
    !pinned.some((entry) => entry.limitation),
  ].every(Boolean);
const components = [];
const sections = [];
const unresolved = [];
function add(ecosystem, item, missingRoot) {
  const { name } = item;
  const version = item.version ?? item.revision;
  const id = `${ecosystem}:${name}@${version}`;
  const notices = item.noticeTexts.map(({ file, text }) => ({
    source: path.isAbsolute(file) ? `installed/${path.basename(file)}` : file,
    text,
  }));
  const pinned = (
    grouped.get(supplementKey({ ...item, ecosystem })) ?? []
  ).filter(requirementsMet);
  notices.push(...pinned.map(readSupplement));
  if (!coverageComplete(`${ecosystem}:${name}`, missingRoot, pinned)) {
    unresolved.push(id);
  }
  // Repeated pod/Swift/npm components retain identity while identical texts in
  // one component are emitted once. No installed paths or timestamps ship.
  const unique = [
    ...new Map(notices.map((notice) => [hash(notice.text), notice])).values(),
  ];
  components.push({
    id,
    revision: item.revision,
    notices: unique.map(({ source, text }) => ({ source, sha256: hash(text) })),
  });
  sections.push(
    `\n${'='.repeat(72)}\n${id}\n${'='.repeat(72)}\n${unique.map(({ source, text }) => `\nSource: ${source}\n\n${text.trim()}\n`).join('')}`,
  );
}
for (const item of npm.packages) {
  add('npm', { ...item, revision: null }, item.licenceFiles.length === 0);
}
for (const item of native.pods) {
  add('pod', { ...item, revision: null }, !item.licenceText);
}
for (const item of native.swiftPackages) {
  add(
    'swift',
    { ...item, name: item.identity },
    item.licenceFiles.length === 0,
  );
}
const text = `Third-party software notices\n\nThese notices cover the installed components identified below.\n${unresolved.length ? `\nNotice coverage still requires review for:\n${unresolved.join('\n')}\n` : ''}${sections.join('')}`;
mkdirSync(destination, { recursive: true });
writeFileSync(path.join(destination, 'ThirdPartyNotices.txt'), text);
writeFileSync(
  path.join(destination, 'ThirdPartyNotices.json'),
  `${JSON.stringify({ sha256: hash(text), components, unresolved }, null, 2)}\n`,
);
process.stdout.write(
  `third-party-notices: ${components.length} components, ${unresolved.length} unresolved notice obligations\n`,
);
