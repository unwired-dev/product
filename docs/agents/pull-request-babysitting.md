# Automated code review and PR babysitting

[CodeRabbit](https://docs.coderabbit.ai/getting-started/yaml-configuration)
reviews non-draft pull requests to `main` as configured in
[`.coderabbit.yaml`](../../.coderabbit.yaml). A `[WIP]` or `[skip review]` title
skips review and blocks [automatic merge](#automatic-merge).

## Implementer PR delivery

An implementation request authorizes full delivery unless it sets an explicit
limit such as "do not push"; then stop before the excluded stage and report what
was done and left undone. Deliver with the global `full-stop` skill: it files
the PR with `file-pr`, babysits it with `babysit-pr` and stops at its gate. This
repository adds:

- **Merging**: the [automatic merger](#automatic-merge) is the owner's merge
  path. Leave it on; full-stop's "prevent automatic merging" step does not
  apply to it. Agents never approve, merge or enable GitHub auto-merge.
- **The PR**: commit the reviewed changes (preserving unrelated work) on the
  task branch and open the PR to `main`, referencing its issue and listing owner
  decisions. In T3 Code, link it with `link_pull_request`. A request that says
  the PR must not merge gets a draft instead (convert a reused ready PR back),
  and delivery ends with the report.
- **Media and design reference**: a PR that changes what the app shows or says
  (UI or user-facing copy) carries, in the body, screenshots of each touched
  platform (iOS, iPadOS, macOS) in Light and Dark, a short video of the new
  behavior recorded from the real app, and a link to each approved Figma frame
  it implements, one per changed state. Delegate the capture to the latest
  available GPT Sol model with high reasoning through `delegate_task`. In the
  capture brief, tell the delegate to use the native runner's cleanup and
  return the verified media and any remaining task-owned temporary paths.
  The parent uploads the media to the PR body before cleaning up the
  remaining paths. Use `gh pr create|edit --attach <file>` (see
  [attaching files](https://docs.github.com/en/github-cli/github-cli/attaching-files-with-github-cli));
  reference each file from the body so it renders in place: `![alt](./shot.png)`
  for an image, `![](./demo.mov)` alone in its paragraph for a video. Do not
  commit it.
  A PR with no visual change says so. Media you could not capture is reported
  as deferred with the reason; a CI E2E capture may stand in.
- A `[skip review]` or `Version packages` title, `do-not-review` label or bot
  author blocks automatic merge. Leave it in place and report the blocker.
- A PR that builds on another unmerged PR is a stacked PR: create and update
  it with the `gh-stack` skill.
- **Gate**: full-stop's "ready to merge" means full-send's merge gate plus
  every [automatic merge](#automatic-merge) condition on the head, except that
  CodeRabbit need not approve the head: the merger's 2-hour fallback covers
  that once CodeRabbit has approved or requested changes on the PR. A PR with
  no such CodeRabbit review (none, or only comments) is not ready; report it as
  blocked on CodeRabbit.

For [CI-only native reproduction](native-validation.md#report-what-the-evidence-proves),
unreviewed diagnostic commits may go on a separate non-draft `[WIP]` PR that is
closed unmerged; product fixes still pass the review.

Each babysitting pass:

- Reads the full feedback state from GitHub: review comments, reviews,
  top-level comments and unresolved review threads.
- Merges `main` into a stale or conflicted head, then meets any new delivery
  requirement the sync brought into agent guides, workflow docs or skills, such
  as a design approval, before pushing.
- Validates each review finding independently, fixes every instance of a valid
  finding's defect class in the PR, and replies with a disposition and that
  audit (a "fixed" reply follows the pushed fix), then resolves the thread.
- Repairs every current required check failure in the PR from the failing leaf
  job's logs, including failures already present on the base branch. When
  `main` itself is red, it also files or updates the issue that owns the failure.
- Treats a failing check that exercises files the PR changed as blocking, even
  when it is not required.
- Runs a fresh `sol-loop` [review](implementation-review.md#review) on any
  behavior change made while babysitting before pushing it.
- Never comments to trigger CodeRabbit or Codex: Codex reviews each push on its
  own, and a comment restarts the merger's 2-hour quiet period.
- Ends once it has handled the feedback and gate state available now.

A missing credential or permission is a blocker to report, not a reason to stop
babysitting other gates.

## Automatic merge

[`.github/workflows/auto-merge.yml`](../../.github/workflows/auto-merge.yml) runs
[`scripts/auto-merge.sh`](../../scripts/auto-merge.sh) whenever a CI, Mac or
Mobile workflow run finishes, and hourly. It squash-merges each open pull
request to `main` that meets every condition:

- It is ready for review, from a same-repository branch, and has no merge conflict.
- Every status check the `main` ruleset requires concluded success or skipped,
  from its required GitHub App when one is specified.
- The head contains the latest `main`, so those checks ran against it.
- Every review thread is resolved.
- Codex reacted with 👍, left no review on the head commit, and either its
  latest "Didn't find any major issues" comment or its Codex Review Summary
  comment's completed Code Review names the current head commit.
- CodeRabbit's latest approving or change-requesting review approves, and its
  `CodeRabbit` status on the head commit is posted by `coderabbitai` and reads
  "Review completed" or "Review approved".

When CodeRabbit has not reviewed the head commit, or its latest review requests
changes, the merger merges once the other conditions hold and the pull request
has had no new commits, comments or reviews for over 2 hours, dismissing any
change request as stale. It never merges a pull request
CodeRabbit is configured to skip, a fork head, a bot-authored pull request, or
the `changeset-release/main` version pull request.
