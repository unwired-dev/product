Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to workspace and build configuration: `package.json` files, `pnpm-workspace.yaml`, `turbo.json`, `.mise.toml`, TypeScript, lint, format, Fallow, Metro, Babel, Jest and Vitest configuration.

One root pnpm workspace and lockfile serve two native hosts that cannot share a renderer. Configuration decides what each bundle contains and which checks are able to fail.

#### Dependencies and catalogs

- A dependency version written literally in a package rather than `catalog:` (shared) or `catalog:mobile` / `catalog:macos` (host-specific). Catalogs are the single place a version changes.
- React, React Native or a renderer-bound library moved into the shared catalog, or a host reading the other host's catalog. Mobile and Mac pin different React and React Native versions on purpose.
- A second lockfile, a nested workspace, or a `packageManager`, `engines` or `.mise.toml` version changed in one place and not the others.
- An install-script permission added or broadened to `true` in `allowBuilds` without a stated need and review of the package, or a package added to `minimumReleaseAgeExclude` without an exact version and a reason for the exception. The first runs install scripts; the second bypasses the release-age delay that protects against a freshly compromised release.
- A new production dependency for something a few lines or an installed dependency already provides, or a runtime dependency placed in `devDependencies` (or the reverse).
- A workspace dependency that inverts the layering: `contracts` depending on anything but `convex` validators, `mail-core` depending on a host, a renderer or the backend, or a host depending on `convex` server code or the legacy harness.
- A package `exports` entry removed or renamed while a consumer still imports it, or a new shared module left reachable only by deep relative import.

#### Checks keep their teeth

- A lint rule switched to `allow`, an `overrides` block or `ignorePatterns` entry widened, a Fallow `ignorePatterns`/`ignoreDependencies`/`entry` addition, or a TypeScript strictness flag relaxed, without a comment giving the reason and the narrowest file scope. Each existing exemption carries its reason and, where temporary, the issue that removes it.
- The Effect policy (`scripts/oxlint-effect-policy.ts`) applied to one lint configuration and not the root, mobile and Mac configurations alike.
- A script renamed or removed while a workflow, `turbo.json` task or documented command still calls it.
- A Turbo task that reads an environment variable missing from its `env` or `globalEnv`, so a cached result is reused across different values; `UNWIRED_MOCK_SCENARIO` must never let a mock build satisfy a production task from cache.
- A test runner configuration that narrows `include`, raises a timeout to hide a slow or racing test, or enables `passWithNoTests`.

#### Bundler boundary

- A Metro resolver change that stops redirecting React and React Native (including subpaths) to the Mac host's packages, or that lets the mobile renderer, Expo, React DOM or backend code resolve into the Mac bundle.
- Mock-session module substitution reachable without a build-time scenario from the fixed list in `scripts/mock-mail-scenarios.json`.
- A Babel or Metro change that alters what ships with no matching update to that host's bundle check (`apps/mobile/scripts/verify-bundle.ts`, `apps/macos/scripts/verify-bundle.ts`).

#### Secrets and environment

- A credential, private key or signing secret committed in configuration or an example file. `.env.example` holds names and placeholders only.
- A new environment variable read by the backend or a build with no entry in `.env.example` and the setup documentation.

#### Release

- A package `version` edited by hand; versions come from Changesets. The mobile and Mac hosts are a fixed group and version together.
