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

Publishing is intentionally not wired yet because current packages are private. Add the publish command and registry credentials when the first public package or app release process is defined.

