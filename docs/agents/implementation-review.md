# Implementation and review

Every implementation hands off to two separate review agents, in sequence,
before delivery:

1. The **OCR reviewer** runs the [Open Code Review delegation](#open-code-review-delegation)
   and the repository rules, including architecture checks.
2. After the OCR reviewer's final report, the **thermo-nuclear reviewer** runs
   the [thermo-nuclear code quality review](#thermo-nuclear-code-quality-review)
   on the result.

Both review agents always use `gpt-6.1-sol` with `high` reasoning, regardless of
the implementer's model or reasoning effort. Pass both settings explicitly.
If that configuration or agent spawning is unavailable, report the review as
blocked. An implementer self-review or a different model does not satisfy it.

The reviewer uses [Alibaba Open Code Review](https://github.com/alibaba/open-code-review)
in [delegation mode](https://github.com/alibaba/open-code-review/blob/main/pages/src/content/docs/en/integrations/delegate.md).
OCR supplies file selection and repository review rules, including architecture
checks; the OpenAI/Codex host performs the review using those resolved rules. Scope `gpt-6.1-sol` and `high` to this review agent's spawn arguments.
Use an OpenAI/Codex host that exposes that model; if it is unavailable, report the
review as blocked. Leave the implementer's model, host defaults and saved OCR
provider/model configuration unchanged. Delegation needs no OCR API key or
provider configuration, and `gpt-6.1-sol` here is the host model identifier.

## Reading responsibilities

The implementer reads the user request, originating issue or specification,
applicable `AGENTS.md` files, source code, topic vocabulary, and operational
guidance for setup, coding conventions, testing and delivery. External API and
framework references remain available for implementation.

Repository architecture documentation belongs exclusively to the review agent:

- `docs/architecture/`, including the reviewer-only architecture index.
- `docs/adr/` and any other architecture decision records.
- `.patterns/` and any other repository architecture guides.
- `.opencodereview/rule.json`, `.opencodereview/rules/` and resolved rule bodies,
  which contain architecture review instructions. Its routing `AGENTS.md` remains implementer-readable.
- `docs/research/`, `docs/qualification/`, and `docs/archive/` for technical design,
  qualification evidence and historical decisions.

The implementer never opens these files, including when a glossary, guide or
skill links to them or requests reading them. Operational guides, coding
conventions, vocabulary and product requirements are separate files that the
implementer can read in full. Keep architecture and design rationale in
`docs/architecture/` or ADRs rather than embedding them in implementer-facing
files. If a guide still mixes them, delegate its separation to the reviewer
before reading the architectural content.

The reviewer owns architecture extraction and edits, updates links to moved
sections, and preserves every requirement and decision. Hand back actionable
outcomes and verification results without copying architecture documents into
the implementer's context. File separation supports this reading policy; it does
not itself restrict filesystem or Git-history access.

## Implementer handoff

1. Before editing, set up the task branch in this order:
   1. Record `git status --short` and classify each existing staged, unstaged
      or untracked change as task-owned or unrelated. Unrelated work stays
      untouched and out of task commits.
   2. Select the branch: the head of the task's open same-repository PR against
      `main` when one exists (a fork head is a delivery blocker to report);
      otherwise a new task branch from the latest `main`.
   3. Work where that branch is usable without moving unrelated changes: this
      checkout, the worktree that already has it checked out (record and
      classify its status too), or a new worktree.
   4. Record the starting commit: the branch head, or for an existing PR with
      commits no completed review covered, its merge-base with `main`.
2. Implement the requested behavior and run the relevant checks under the
   [testing policy](testing.md). Documentation changes use formatting and local
   link checks.
3. Spawn the OCR reviewer with these explicit arguments:

   ```json
   {
     "task_name": "implementation_review",
     "model": "gpt-6.1-sol",
     "reasoning_effort": "high",
     "fork_turns": "none",
     "message": "<self-contained review handoff>"
   }
   ```

   Include the checkout path, user request and issue/specification, starting
   commit, implementation summary, task-owned files, pre-existing changes, checks
   and their results, and known limitations. Tell it to read this workflow, run the
   Open Code Review delegation step below, apply the repository rules and their
   required architecture-source reading, review the implementation, fix validated issues,
   and rerun the relevant checks. Include the actual comparison to review:

   - For uncommitted work, inspect the staged and unstaged diffs and task-owned
     untracked files. A commit-only diff does not cover this work.
   - For committed work, pin the starting commit or merge-base and inspect the
     full task diff, plus any task-owned uncommitted files.

4. Pause all implementer writes to the shared checkout while the OCR reviewer
   owns it. Wait for its final report.
5. Then spawn the thermo-nuclear reviewer with the same explicit arguments and
   `"task_name": "thermo_nuclear_review"`. Write it a separate self-contained
   message with the same context and comparison, plus the OCR reviewer's final
   report. Tell it to read this workflow and follow the
   [thermo-nuclear code quality review](#thermo-nuclear-code-quality-review)
   instead of the OCR delegation step. Keep the comparison pinned to the
   starting commit so it covers the implementation and the OCR reviewer's fixes.
   Keep implementer writes paused until its final report. Never run the two
   reviewers at once.
6. Both reviews form one implementation review. Additional implementation
   edits, including fixes after review or PR feedback, require another pinned
   review by both reviewers. Give every reviewer and its children the same ownership boundary: no PR
   watchers, scheduled work, or writes after their final report. A notification
   cannot renew checkout ownership. Stop any pre-existing review watcher before
   returning the checkout; a later review starts as a new delegated task with a
   fresh pinned handoff.

## Reviewer responsibilities

1. Read applicable agent guides and this workflow. Run the
   [Open Code Review delegation step](#open-code-review-delegation) for the
   handoff's actual comparison before reviewing the implementation.
2. Apply the resolved repository rules as the architecture and standards
   checklist within that review pass, including their mandatory source-reading
   and scope/supersession checks. Architecture docs remain authoritative;
   resolving a rule is not evidence that its checks passed. The
   [reviewer-only coverage map](../architecture/open-code-review.md) records the
   migration of the former architecture checklist and source routing.
3. Review the entire task against its requested behavior and resolved rules.
   Use the installed `code-review` guidance where applicable, with the handoff's
   actual comparison and specification. For OCR-excluded task-owned files, apply
   the same repository checklist through the appropriate artifact review.
   When the task touches React, React Native or Expo code, invoke
   `vercel-react-native-skills` and `vercel-composition-patterns` and review
   that code against both.
4. Independently validate each finding. Fix confirmed issues directly in the
   checkout, preserving unrelated work. Update affected tests and documentation,
   including architecture docs when needed. This assignment includes fixes,
   even when a review skill's default output is only a findings report.
5. Run the checks appropriate to the fixes, inspect the final diff, and review
   the corrected result again. Repeat until there are no unresolved issues within
   the authorized scope. Reviewer fixes remain within this review and do not
   spawn another implementation reviewer.
6. Return the reviewed scope, OCR version, preview mode and refs, file coverage,
   applicable rule sections and source references with their dispositions,
   findings and their dispositions, files changed,
   checks and results, unavailable checks, and the
   [decision panel](#decision-panel) outcome for any finding that would change
   product scope or an architectural decision. Do not silently alter product scope or architectural decisions
   to make an implementation pass.
7. The final report ends reviewer and child-agent write ownership. Do not start
   PR watchers or recurring tasks in review threads. Stop any existing review
   watcher before reporting, and do not act on later PR notifications or resume
   writes without a new delegated review and explicit checkout handoff.

## Thermo-nuclear code quality review

The thermo-nuclear reviewer has the same responsibilities, reading access, write
ownership and final-report boundary as the OCR reviewer above, with this review
pass in place of the OCR delegation step:

1. Read the global `thermo-nuclear-code-quality-review` skill's `SKILL.md` from
   the host's global skill install and follow it. The skill disables model
   invocation, so read the file instead of invoking it. If the skill is not
   installed, report the review as blocked.
2. Review the full task diff from the pinned starting commit, including the OCR
   reviewer's fixes and task-owned uncommitted files. A documentation-only task
   records that no code changed and reviews any scripts or config it touched.
3. Validate each finding and apply behavior-preserving fixes directly. Resolve
   rules with `ocr delegate rule` for every file the fixes touch and keep the
   result within those rules. A fix that would change product scope or an
   architectural decision goes to the [decision panel](#decision-panel).
4. Rerun the relevant checks and review the corrected result again. Return the
   reviewed scope, findings and their dispositions, files changed, checks and
   results, unavailable checks, and any panel outcomes.

## Decision panel

Implementation and review continue without waiting for the user. Any decision
that would otherwise pause the work for a user answer goes to a three-model
panel instead: ambiguous or missing requirements, scope and product choices,
competing approaches, and review findings that would change product scope or an
architectural decision. Access the agent lacks (credentials, accounts, devices,
paid services) is an unavailable prerequisite, not a decision; report it as such.
Issue identification, `in progress` takeovers and explicit user limits stay with
the user.

1. Frame the question with the context a fresh agent needs: the issue or
   request, the relevant code and constraints, and exactly two concrete,
   mutually exclusive options with their consequences. Resolve questions with
   more alternatives through a short series of binary ballots.
2. Delegate it in parallel to three read-only panelists with `high` reasoning:
   `claude-fable-5-1`, `gpt-6.1-sol` and `gpt-6-astra`. Each receives the same
   self-contained prompt, no conversation history, and the implementer's
   reading boundary. Each returns one option and a short rationale, and makes
   no edits.
3. The option with at least two matching votes wins; apply it and continue.
   Three valid votes on two options always produce a majority.
4. Record each decision (question, options, votes, rationales and outcome) in
   the final report and the PR description so the user can override it later.

Use a bounded deadline for each round. Unavailable, failed or timed-out
panelists and invalid votes do not count. Two matching votes still suffice. If
there is no majority, retry once with the same options and the available
rationales, attempting all three models again. If two matching votes remain
unavailable, report the model prerequisite as blocked; never apply an option
without a majority. Continue independent work while the prerequisite is blocked.

## Open Code Review delegation

Run these commands from the handoff's checkout while the reviewer owns it.
Use `ocr` v1.12.11, the verified version for project rule merging and file selection
in this workflow. Revalidate those contracts before adopting another version.
Check `ocr --version` first. If missing, use the upstream
[release binary](https://github.com/alibaba/open-code-review/releases/tag/v1.12.11)
for the host platform or the upstream installation instructions, honoring the
repository toolchain policy. An unavailable CLI or failed delegation command
leaves this review step incomplete; report the error rather than skipping it.

OCR automatically discovers the repository's `.opencodereview/rule.json`.
Do not substitute a `--rule` override or saved global rules for this project
checklist. The reviewer may read the config and resolved bodies; the implementer
receives coverage and findings without their architecture content. The
[upstream rule format](https://github.com/alibaba/open-code-review/blob/main/pages/src/content/docs/en/review-rules.md)
describes first-match resolution and `merge_system_rule`. This repository
resolves one path rule per file. Each path rule requires the common checklist
`.opencodereview/rules/common.md` as its first instruction; read that checklist
once per review and apply it to every task-owned file. Embedded language rules
are merged except where they contradict the repository's conventions.
The config's targeted includes admit owned documentation and tests; explicit excludes
keep dependencies, generated/build output and task probes out. Inclusion is a
bypass of default filters, not a whitelist; exclusions still require a recorded
full-task disposition.

1. Preview the requested scope, preserving the handoff's pinned starting commit.
   For task-owned staged, unstaged and untracked changes, use workspace mode:

   ```sh
   ocr delegate preview --format json
   ```

   For committed work, use the pinned starting commit and reviewed head:

   ```sh
   ocr delegate preview --format json --from <starting-commit> --to <reviewed-head>
   ```

   When task-owned workspace changes accompany committed work, run both previews.
   Reconcile their paths with the full task diff and task-owned untracked files.
   Keep pre-existing changes outside the task out of the review and preserve them.
   Range mode reports a `merge_base`; verify it matches the intended baseline
   before using it to read diffs. Do not substitute a single-commit review for a
   multi-commit task.

2. Resolve rules for the task-owned `reviewable_files` paths from the previews:

   ```sh
   ocr delegate rule --format json <path1> <path2>
   ```

   Confirm every task-owned reviewable path resolves a project path rule from
   `.opencodereview/rules/`, and read the common checklist those rules require.
   Use `ocr rules check <path>` to inspect the selected source and pattern when
   needed, keeping rule bodies in the reviewer context. A `rule file not found`
   warning, or a missing, invalid or overridden repository rule, leaves this step
   incomplete; fix its resolution before proceeding. Read the authoritative
   sources required by the common rules and the conditional sections applicable
   to the changed behavior and collaborating modules.

   Pass paths as separate quoted arguments when they contain shell-special
   characters. Batch large file lists. Use the same range arguments as the
   preview when resolving committed-file rules. An empty reviewable list needs
   no path-specific rule command. In that case, read the project checklist
   directly and apply its common and relevant conditional sections to the full
   task; document why OCR selected no paths.

3. Review every task-owned file using its diff, full-file context and matching
   rule group. For tracked workspace changes, read `git diff HEAD -- <path>`;
   read task-owned untracked files directly. For committed work, read the diff
   from the verified baseline to the pinned head. Maintain a coverage checklist
   keyed by `(path, status)` because a staged deletion and untracked recreation
   can share a path. Account for every preview entry with a disposition.
   OCR exclusions, including unsupported documentation files, do not reduce the
   repository review scope: review task-owned excluded files under the repository
   checklist directly and record that OCR did not resolve rules for those paths.
   Documentation and owned tests normally receive OCR rules through the project
   includes; inspect unexpected exclusions before accepting them.
4. Validate and fix findings under the reviewer responsibilities above. After
   fixes, refresh workspace coverage and rules for changed or new task-owned
   files, then review the corrected result. Include coverage and unresolved
   errors and architecture-check dispositions in the final report. Architecture
   checking is performed through this resolved-rule review pass; CLI success
   alone does not satisfy it. Review completion and required CI remain separate
   gates.

## Improve the review rules

The review rules improve over time from the feedback they miss. When pull-request
review comments from people, CodeRabbit, Codex or another review bot are validated,
when a defect escapes an earlier review, or when a reviewer finding turns out to be
a false positive, include those cases in the next reviewer handoff as rule-improvement
candidates: the comment or defect, its location, and the validated disposition.

The reviewer decides whether each candidate is a defect class the rules should
name, a wrong or stale rule, or a one-off, then updates `.opencodereview/rules/`
and reports each rule change or declined candidate. The implementer supplies the
evidence and never opens the rule files. The same pass covers OCR version updates
and new code areas that need their own rule.

## Completion

The implementer delivers only after both required reviewers have finished fixing
validated issues and verifying the final artifact, including the Open Code Review
delegation step and the thermo-nuclear code quality review. Unresolved findings or an
unavailable reviewer leave implementation review incomplete; report them
accurately. Review completion and required CI remain independent gates.
Delivery then continues automatically, within any explicit user limit: the
implementer opens the PR and babysits it under the [implementer PR delivery](pull-request-babysitting.md#implementer-pr-delivery)
policy. Reviewers never open or babysit PRs.
