Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to `.github/`: workflows, actions and repository automation.

Workflows hold the release credentials (App Store Connect key, Convex URL, OAuth client) and decide what counts as a passing pull request. The merged workflow rule covers generic injection, permission and pinning defects; these add the repository's contracts.

#### Trust boundary

- `.github/workflows/auto-merge.yml` executing a manually dispatched branch's script with the ruleset-bypass `GH_TOKEN`. Keep the job and checkout on trusted `main`; otherwise unmerged code receives merge authority.
- Pull-request-controlled code executed with secrets or a write token in scope: a `pull_request_target` or `workflow_run` job that checks out the head, a reusable workflow given `secrets: inherit`, or a release or TestFlight job reachable from a pull request event.
- A job or step that needs a secret receiving it through anything wider than that step's `env`.
- `permissions` widened beyond `contents: read` at workflow level; a job that needs more declares it for that job only.
- A third-party action referenced by tag or branch rather than a full commit SHA with the version in a comment.
- The PR babysitter's credential-free isolation weakened: PR-controlled code run outside its sandbox, or permissions broadened so local validation passes. `scripts/check-pr-babysitter-contract.sh` checks the documented contract.

#### Gates stay honest

- A required check removed, made `continue-on-error`, skipped by a path filter that misses files it covers, or changed to pass with zero tests selected.
- A workflow command that diverges from the local validation command documented in `README.md` and `docs/expo-client.md`, so CI and local runs prove different things.
- A path filter that omits a dependency of the job: shared `packages/`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `scripts/` or the workflow file itself.
- A native or bundle job whose evidence is described more broadly than it is. A Hermes export checks the bundle; a Simulator journey checks that journey; neither is device, provider or credential qualification.
- A legacy Swift job presented as a merge gate for the replacement hosts.

#### Runs are bounded and owned

- A job without `timeout-minutes`, or a pull-request workflow without a `concurrency` group that cancels superseded runs. Release and TestFlight runs never cancel in progress.
- A native job that reuses a shared Simulator, DerivedData or result path, or that skips cleanup on failure or cancellation.
- A cache keyed so a pull request can poison a cache that a privileged run restores, or a cache that stores credentials or signing material.
- An artifact that can contain secrets, signing material or account data.

#### Toolchain

- A Node, pnpm, Xcode or tool version that differs from `.mise.toml` and the `packageManager` field, or an install step without the frozen lockfile.
