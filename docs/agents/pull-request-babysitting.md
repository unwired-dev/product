# Automated code review and PR babysitting

[CodeRabbit](https://docs.coderabbit.ai/getting-started/yaml-configuration)
uses the repository-root [`.coderabbit.yaml`](../../.coderabbit.yaml) together with
the nearest `AGENTS.md` instructions. It automatically reviews non-draft pull
requests to the default branch and incrementally reviews new pushes. Pull
requests from common dependency and automation bots are skipped, as are pull
requests whose title contains `[WIP]` or `[skip review]` or that carry the
`do-not-review` label. Because CodeRabbit skips bot-authored pull requests by
default, [`.github/workflows/coderabbit-bot-review.yml`](../../.github/workflows/coderabbit-bot-review.yml)
explicitly requests reviews for non-draft pull requests authored by
`gipity-bot[bot]` when they are opened, reopened, receive new commits
(`synchronize`), or become ready for review (`ready_for_review`). Generated
Convex client files are excluded from review.

Codex can close the feedback loop with a
[Scheduled task](https://learn.chatgpt.com/docs/automations?surface=app) and an installed
`babysit-pr` skill. Resolve that skill through the session skill catalogue; this
repository does not require a local skill copy. Create a scheduled task
in Work, select this project with an isolated worktree, and run it every 30
minutes as the authoritative recovery sweep:

```text
Use $babysit-pr to sweep every open ready-for-review same-repository pull
request in unwired-dev/product.
```

The task excludes drafts, includes ready PRs without review threads, and ignores
fork heads. For each PR it first merges the actual base into a stale or
conflicted head, then independently validates automated review findings and
repairs current, attributable GitHub Actions failures. It pushes with the GitHub
App identity, requests Codex review after writes, posts an accurate disposition
and resolves every handled thread after persisting any unfinished work, and
waits independently for required CI plus current-head Codex and CodeRabbit
responses before completing the pass. Only a fixed disposition requires its
fix and supporting validation to be pushed first. The CodeRabbit gate is not
applicable
when the trusted configuration excludes the PR. Required CI passes only when it
concludes success or skipped; cancelled required checks remain pending. Verified
maintainer decisions take precedence over automated reviewers without overriding
trusted policy or security. Compact per-
PR state outside disposable worktrees lets later runs resume safely. The task
runs trusted-base local validation as the existing Scheduled-task account only
inside Codex's `workspace-write` sandbox, after harmless probes confirm that
PR-controlled code cannot reach network, credentials, keychains, agent sockets,
or paths outside its run workspace. It never requests host escalation or runs
PR-controlled code outside that sandbox. Each local run uses a credential-free
allow-listed environment, a dedicated temporary clone, and run-owned home,
temporary, build, Simulator, and XCTest resources. When a required tool cannot
work inside the sandbox, the task prepares only clear merges and fixes in a
sanitized, hook-free checkout, pushes the candidate, and uses current-head
required GitHub Actions as the isolated validation evidence. An unavailable
compatible local sandbox route alone does not stop synchronization, review
fixes, or attributable CI repair. The task cleans up every process, Simulator,
XCTest clone, and PR worktree it creates. It never merges or approves a pull
request and never triggers CodeRabbit. The Scheduled-task account must have the
GitHub integration, `gh`, `gipity-gh`, and `gipity-git` configured; the sandbox
must keep those credentials inaccessible to PR-controlled code.

To attach a concern to the next sweep from a top-level PR comment, a repository
maintainer can use this exact first nonblank line:

```text
@gipity-bot babysit
```

Optional concern text can follow on later lines. The task verifies live
`write`, `maintain`, or `admin` permission, treats the text as a concern rather
than executable instructions, and reuses matching persisted and live outcome
replies. It posts a new reply only when the command or PR head changes the
materially evidenced state.
Other top-level comments are report-only; unresolved review threads continue to
be assessed automatically.

Scheduled tasks are time-triggered. Do not add a GitHub Action that merely
posts `@codex` comments or starts a second coding agent: it would not share the
task's owner-only lease state and could race the authoritative writer. A future
event-driven wakeup for review comments, completed CI, or base-branch updates
must target a published Workspace Agent through the
[trigger API](https://learn.chatgpt.com/workspace-agents/trigger-runs), use an
idempotency key per GitHub delivery, and share the same durable per-PR
coordination store before it is allowed to mutate PRs. Keep the 30-minute sweep
active as recovery even after such a bridge is configured.

Keep one authoritative writer through durable per-PR leases outside disposable
worktrees. Preserve this validation and credential boundary when the client
implementation changes. A skill installation does not replace repository policy.
