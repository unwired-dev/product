# Changesets

Use Changesets for release-intent notes, package version bumps, and generated package changelogs.

Create a changeset when a change should appear in release notes:

```sh
pnpm changeset
```

Apply pending changesets when preparing a release:

```sh
pnpm version-packages
```

Packages are private: they are versioned but never published. The [Release workflow](../docs/testflight.md#versioned-releases) applies pending changesets in a version pull request; merging it tags the release and uploads both hosts to TestFlight. CI rejects a changeset that targets a package outside the workspace.

