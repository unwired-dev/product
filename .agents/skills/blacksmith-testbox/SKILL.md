---
name: blacksmith-testbox
description: Use the repository's Blacksmith Testbox to run TypeScript lint, format, typecheck, tests, and Fallow with Linux CI parity against local changes. Trigger when validating TypeScript changes, reproducing Linux CI failures, or checking work before commit or push.
---

# Blacksmith Testbox

Use Testbox for the repository's Linux TypeScript checks. It hydrates the same
Node, pnpm, dependency, and Turbo-cache environment as CI, then syncs local
changes before each command.

Testboxes are Linux-only. Continue to run the documented Apple lint and Xcode
test commands locally or through the macOS CI job.

## Start a session

Run every Testbox command from the repository root. The CLI syncs that directory
with `rsync --delete`; starting it from a subdirectory can remove the rest of the
remote checkout.

If the CLI is missing, install and authenticate it using Blacksmith's documented
flow:

```sh
curl -fsSL https://get.blacksmith.sh | sh
blacksmith auth login
```

Warm one Testbox at the beginning of a validation session and save its ID:

```sh
blacksmith testbox warmup blacksmith-testbox.yml --job typescript
```

Reuse that ID throughout the task. `run` waits for hydration automatically, so
do not poll or create another Testbox while the first one starts.

## Run checks

Run focused checks first, then the full required TypeScript validation:

```sh
blacksmith testbox run --id <ID> "pnpm lint"
blacksmith testbox run --id <ID> "pnpm format"
blacksmith testbox run --id <ID> "pnpm turbo run check-types"
blacksmith testbox run --id <ID> "pnpm test"
blacksmith testbox run --id <ID> "pnpm fallow"
```

Testbox does not sync ignored dependency directories. When `package.json`,
`pnpm-lock.yaml`, or `pnpm-workspace.yaml` changes, install before checking:

```sh
blacksmith testbox run --id <ID> "pnpm install --frozen-lockfile && pnpm test"
```

Fix failures and rerun against the same ID so only changed files are synced.
Stop the session when validation is complete:

```sh
blacksmith testbox stop --id <ID>
```
