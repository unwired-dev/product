# Automated code review and PR babysitting

[CodeRabbit](https://docs.coderabbit.ai/getting-started/yaml-configuration)
reviews non-draft pull requests to `main` as configured in
[`.coderabbit.yaml`](../../.coderabbit.yaml). A `[WIP]` or `[skip review]` title
skips review and blocks [automatic merge](#automatic-merge).

## Implementer PR delivery

An implementation request authorizes full delivery unless it sets an explicit
limit such as "do not push"; then stop before the excluded stage and report what
was done and left undone. After the
[implementation review](implementation-review.md#review) finishes, the implementer:

1. Commits the reviewed changes (preserving unrelated work) on the task branch
   created or selected before implementation, and pushes the branch.
2. Updates the task's open PR, or opens one to `main` referencing its issue,
   with the body from the `pr` skill and any owner decisions. In T3 Code, link the PR to the thread with `link_pull_request`.
   - Mark the PR ready for review: promote a draft and drop a `[WIP]` title marker.
   - When the request forbids merging, make it a draft instead (convert a reused
     ready PR back) and end delivery with the report, without babysitting.
   - A `[skip review]` or `Version packages` title, `do-not-review` label or bot
     author also blocks automatic merge. Leave it in place and report the blocker.
   - A PR that builds on another unmerged PR is a stacked PR: create and update
     it with the `gh-stack` skill.
3. Invokes the `babysit-pr` skill for that PR alone and keeps it until the PR is
   merged or closed. In T3 Code, call `watch_pull_request` and end the turn;
   each wakeup runs one pass. Without T3 watching, report that and use the
   host's PR watcher or the skill's monitoring, never a recurring schedule.

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
- Gets a fresh [review](implementation-review.md#review) for any behavior change
  made while babysitting before pushing it.
- Never comments to trigger CodeRabbit or Codex: Codex reviews each push on its
  own, and a comment restarts the merger's 2-hour quiet period.
- Ends once it has handled the feedback and gate state available now.

When the PR is merged or closed, call `unwatch_pull_request` in T3 Code and
report the outcome. A missing credential or permission is a blocker to report,
not a reason to stop babysitting other gates. Agents never approve or merge pull
requests; the automatic merger does.

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
