# Packages

Each workspace package here is a deep module: a lot of behavior behind a small
interface. Its public surface is its **entry points**, the files its
`package.json` `exports` map names. Everything else in the package is private.

```text
packages/<name>/
  package.json   ← "exports": { ".": "./src/index.ts", "./client": "./src/client.ts" }
  src/
    index.ts     ← entry point (exported)
    client.ts    ← another entry point (exported)
    model.ts     ← private: only this package imports it
  test/          ← tests and fixtures, private to tests
```

Import a package by name (`@private-email/<name>/client`), never by a relative
path into its folder. Add an entry point by adding a small file and naming it in
`exports`. Do not add barrel files that re-export a whole package: several small
entry points keep each consumer's dependency narrow.

`pnpm lint:boundaries` runs [dependency-cruiser](../.dependency-cruiser.cjs) over
repository sources, including packages, apps and root tooling. It runs in CI through
`turbo run lint:boundaries` and enforces these rules:

- **Entry-point boundary.** Apps and other packages import only a package's
  entry points, never its other files.
- **Intra-package freedom.** A package's own source files import each other
  freely.
- **Tests through the entry points.** Files under `<name>/test/` import entry
  points and their own `test/` fixtures, never package internals, including their
  own package's internals. Nothing outside tests imports from a `test/` folder.
- **No cycles.** No dependency cycles anywhere.

Violations that predate the check are recorded in
[`.dependency-cruiser-known-violations.json`](../.dependency-cruiser-known-violations.json)
and ignored. New violations fail. After fixing a recorded one, regenerate the
baseline with `pnpm exec depcruise . --baseline --baseline-mode shrink-only`.
This removes fixed violations without accepting new ones.
