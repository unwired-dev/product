// Print the licence each third-party npm package with sources in a JavaScript
// bundle's source map declares. This records declarations; it does not decide
// licence compatibility or produce the notices the build owes (#1960).
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { argv, cwd, exit, stderr, stdout } from 'node:process';

import * as Schema from 'effect/Schema';

import { noticeFiles } from './notice-files.mjs';

const SourceMap = Schema.Struct({ sources: Schema.Array(Schema.String) });
// A legacy object or array `license` is not a declared licence string.
const Package = Schema.Struct({
  name: Schema.String,
  version: Schema.String,
  license: Schema.optional(Schema.Unknown),
});

const fail = (message) => {
  stderr.write(`licence-inventory: ${message}\n`);
  exit(1);
};

const read = (schema, file) => {
  try {
    return Schema.decodeSync(Schema.fromJsonString(schema))(
      readFileSync(file, 'utf8'),
    );
  } catch (error) {
    return fail(`unreadable ${file}: ${error.message}`);
  }
};

if (!argv.at(2)) {
  fail('usage: licence-inventory.mjs <main.jsbundle.map>');
}
const map = path.resolve(argv.at(2));
const includeText = argv.includes('--include-text');
// Expo lists sources from the Metro server root, run from the checkout.
const located = (file) => (existsSync(file) ? file : path.join(cwd(), file));
const sources = read(SourceMap, map).sources.map((source) =>
  path.resolve(path.dirname(map), source),
);
// A module that embeds a bundle of its own, such as the Draft editor page
// (`packages/draft-editor/build.cjs`), lists that bundle's sources beside it.
const embedded = sources
  .filter((source) => source.endsWith('.js'))
  .map((source) => located(source.replace(/\.js$/u, '.sources.json')))
  .filter((record) => existsSync(record))
  .flatMap((record) =>
    read(SourceMap, record).sources.map((source) =>
      path.resolve(path.dirname(record), source),
    ),
  );
// A package is the innermost node_modules folder holding a source, so
// workspace sources, which Metro lists by their real paths, are not packages.
const roots = new Set(
  [...sources, ...embedded]
    .map(
      (source) =>
        /^(?<root>.*\/node_modules\/(?:@[^/]+\/)?[^/]+)\//u.exec(source)?.groups
          .root,
    )
    .filter((root) => root !== undefined)
    .map(located),
);
const packages = new Map();
for (const root of roots) {
  const { name, version, license } = read(
    Package,
    path.join(root, 'package.json'),
  );
  packages.set(`${name}@${version}`, {
    name,
    version,
    licence: typeof license === 'string' ? license : null,
    licenceFiles: noticeFiles(root)
      .map(({ file }) => file)
      .toSorted(),
    ...(includeText ? { noticeTexts: noticeFiles(root, true) } : {}),
  });
}
// Order by name, then version, in code units, independent of the locale.
const order = (a, b) => (a < b ? -1 : Number(a > b));
const listed = [...packages.values()].toSorted(
  (a, b) => order(a.name, b.name) || order(a.version, b.version),
);
const ids = (predicate) =>
  listed.filter(predicate).map((item) => `${item.name}@${item.version}`);

stdout.write(
  `${JSON.stringify(
    {
      packages: listed,
      undeclared: ids((item) => item.licence === null),
      withoutLicenceFile: ids((item) => item.licenceFiles.length === 0),
    },
    null,
    2,
  )}\n`,
);
