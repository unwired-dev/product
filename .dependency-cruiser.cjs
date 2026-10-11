// @ts-check
// Deep-module enforcement for dependency-cruiser.
//
// Each workspace package under packages/ is a DEEP MODULE: a lot of behaviour
// behind a small interface. A package's PUBLIC SURFACE is its ENTRY POINTS:
// the files its package.json `exports` map names. Everything else in the
// package is private. Prefer several small entry points over one barrel.

const fs = require('node:fs');
const path = require('node:path');

/** Where packages live. One immediate child dir per package (flat, no nesting). */
const PACKAGES_ROOT = 'packages';

const R = PACKAGES_ROOT;
/** Every package's entry points, as anchored regex alternatives. */
const ENTRY_POINTS = fs
  .readdirSync(path.join(__dirname, R))
  .flatMap((name) => {
    const manifest = path.join(__dirname, R, name, 'package.json');
    if (!fs.existsSync(manifest)) {
      return [];
    }
    // shortcut: assumes string-valued `exports` entries; add condition handling if a package adopts them.
    const exports = require(manifest).exports ?? {};
    return Object.values(exports).map((target) =>
      path.posix
        .join(R, name, target)
        .replaceAll(/[.*+?^${}()|[\]\\]/gu, String.raw`\$&`),
    );
  })
  .join('|');

/**
 * A package's private files: anything inside a package that is not an entry
 * point.
 */
const PACKAGE_INTERNALS = {
  path: `^${R}/[^/]+/`,
  pathNot: `^(${ENTRY_POINTS})$`,
};

/** @type {import('dependency-cruiser').IConfiguration} */
module.exports = {
  forbidden: [
    {
      name: 'entrypoint-boundary-from-app',
      comment:
        "App/root code may import a package's entry points (its package.json exports), but nothing else inside it.",
      severity: 'error',
      from: { pathNot: `^${R}/` },
      to: PACKAGE_INTERNALS,
    },
    {
      name: 'entrypoint-boundary-across-packages',
      comment:
        "A package's own files import each other freely, but may reach OTHER packages only through their entry points.",
      severity: 'error',
      from: { path: `^${R}/([^/]+)/`, pathNot: `^${R}/[^/]+/test/` },
      to: {
        path: PACKAGE_INTERNALS.path,
        pathNot: [PACKAGE_INTERNALS.pathNot, `^${R}/$1/`],
      },
    },
    {
      name: 'package-by-name-from-app',
      comment:
        'App/root code imports a package by its name, never by a relative path into its folder, even to an entry point.',
      severity: 'error',
      from: { pathNot: `^${R}/` },
      to: { path: `^${R}/`, dependencyTypes: ['local'] },
    },
    {
      name: 'package-by-name-across-packages',
      comment:
        'A package imports another package by its name, never by a relative path into its folder, even to an entry point.',
      severity: 'error',
      from: { path: `^${R}/([^/]+)/` },
      to: { path: `^${R}/`, pathNot: `^${R}/$1/`, dependencyTypes: ['local'] },
    },
    {
      name: 'tests-through-entrypoints',
      comment:
        "A package's tests exercise it through its entry points: they may import any package's entry points and their own test/ fixtures, but never any package's internals, not even their own.",
      severity: 'error',
      from: { path: `^${R}/([^/]+)/test/` },
      to: {
        path: PACKAGE_INTERNALS.path,
        pathNot: [PACKAGE_INTERNALS.pathNot, `^${R}/$1/test/`],
      },
    },
    {
      name: 'tests-folder-is-private',
      comment:
        "A package's test/ folder is reachable only from tests: nothing else may import fixtures.",
      severity: 'error',
      from: { pathNot: `^${R}/[^/]+/test/` },
      to: { path: `^${R}/[^/]+/test/` },
    },
    {
      name: 'no-circular',
      comment: 'No dependency cycles.',
      severity: 'error',
      from: {},
      to: { circular: true },
    },

    // --- Layering (optional, off by default) ----------------------------------
    // Entry points control HOW you import. Layering controls WHICH packages may
    // depend on which. Add rules here, e.g.:
    //
    // {
    //   name: "contracts-depends-on-nothing",
    //   severity: "error",
    //   from: { path: `^${R}/contracts/` },
    //   to:   { path: `^${R}/(?!contracts/)` },
    // },
  ],
  options: {
    doNotFollow: { path: 'node_modules' },
    // Generated output, task probes and native projects are outside the source graph.
    exclude: {
      path: '(^|/)(node_modules|\\.git|\\.turbo|\\.expo)/|^(artifacts|scratchpad)/|^apps/mobile/(ios|android)/|^apps/macos/macos/',
    },
    tsPreCompilationDeps: true,
    enhancedResolveOptions: {
      exportsFields: ['exports'],
      conditionNames: ['import', 'require', 'node', 'default', 'types'],
      extensions: [
        '.ts',
        '.tsx',
        '.mts',
        '.cts',
        '.js',
        '.jsx',
        '.mjs',
        '.cjs',
        '.json',
      ],
    },
  },
};
