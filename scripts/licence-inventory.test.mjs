import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';

import * as Schema from 'effect/Schema';

const decodeJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);

const root = path.join(import.meta.dirname, '..');
const script = path.join(root, 'scripts/licence-inventory.mjs');

const write = (file, text = '') => {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, text);
};

// A pnpm-layout checkout: a scoped package, a package nested in another, a
// second install of the same version listed from the Metro server root as
// Expo does, one with a legacy licence object and a workspace package.
function fixture() {
  mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
  const directory = mkdtempSync(
    path.join(root, 'scratchpad/licence-inventory-'),
  );
  const store = path.join(directory, 'node_modules/.pnpm');
  const install = (folder, manifest, ...files) => {
    write(path.join(folder, 'package.json'), JSON.stringify(manifest));
    for (const file of files) {
      write(path.join(folder, file));
    }
    return path.join(folder, 'index.js');
  };
  const scoped = path.join(store, '@scope+kit@1.0.0/node_modules/@scope/kit');
  const outer = path.join(store, 'outer@2.0.0/node_modules/outer');
  const sources = [
    '__prelude__',
    path.join(directory, 'packages/mail-core/src/index.ts'),
    install(
      scoped,
      { name: '@scope/kit', version: '1.0.0', license: 'MIT' },
      'LICENSE',
      'NOTICE.md',
      'README.md',
    ),
    path.join(scoped, 'dist/esm/deep.js'),
    install(
      outer,
      { name: 'outer', version: '2.0.0', license: 'Apache-2.0' },
      'LICENCE-APACHE',
    ),
    install(path.join(outer, 'node_modules/inner'), {
      name: 'inner',
      version: '0.1.0',
    }),
    install(
      path.join(store, 'legacy@3.0.0_react@19/node_modules/legacy'),
      { name: 'legacy', version: '3.0.0', license: { type: 'BSD' } },
      'COPYING',
    ),
    install(
      path.join(store, 'legacy@3.0.0_react@18/node_modules/legacy'),
      { name: 'legacy', version: '3.0.0', license: { type: 'BSD' } },
      'COPYING',
    ),
  ];
  const map = path.join(directory, 'artifacts/ios-sources/main.jsbundle.map');
  write(
    map,
    JSON.stringify({
      sources: sources.map((source) => {
        if (source.includes('/outer@')) {
          return path.relative(path.dirname(map), source);
        }
        return source.includes('_react@18/')
          ? `/${path.relative(directory, source)}`
          : source;
      }),
    }),
  );
  return { directory, map, outer };
}

const inventory = (map, cwd) =>
  spawnSync(process.execPath, [script, map], { cwd, encoding: 'utf8' });

test('licence inventory records bundled third-party packages', () => {
  const { directory, map, outer } = fixture();
  try {
    const result = inventory(map, directory);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(inventory(map, directory).stdout, result.stdout);
    assert.deepEqual(decodeJson(result.stdout), {
      packages: [
        {
          name: '@scope/kit',
          version: '1.0.0',
          licence: 'MIT',
          licenceFiles: ['LICENSE', 'NOTICE.md'],
        },
        {
          name: 'inner',
          version: '0.1.0',
          licence: null,
          licenceFiles: [],
        },
        {
          name: 'legacy',
          version: '3.0.0',
          licence: null,
          licenceFiles: ['COPYING'],
        },
        {
          name: 'outer',
          version: '2.0.0',
          licence: 'Apache-2.0',
          licenceFiles: ['LICENCE-APACHE'],
        },
      ],
      undeclared: ['inner@0.1.0', 'legacy@3.0.0'],
      withoutLicenceFile: ['inner@0.1.0'],
    });

    writeFileSync(path.join(outer, 'package.json'), '{"name": "outer"}');
    const unreadable = inventory(map, directory);
    assert.equal(unreadable.status, 1);
    assert.match(unreadable.stderr, /unreadable .*outer\/package\.json/u);
    assert.equal(unreadable.stdout, '');

    writeFileSync(map, 'not a source map');
    assert.equal(inventory(map, directory).status, 1);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
