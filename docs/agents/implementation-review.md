# Implementation and review

Use this workflow for implementation, later fixes and PR feedback. For UI work,
apply [native component selection](native-components.md). Preserve unrelated work,
review the final artifact independently and keep review, CI and release evidence
as separate gates.

## Review depth

Every implementation starts with a separate
[simplicity and reuse review](#simplicity-and-reuse-review). After its final report,
run the applicable independent documentation or OCR review, then any required
maintainability and design reviews in that order. Record the applicable rows and
their reasons in the handoff. Later review depth follows the changed contract
rather than the task's size or file count.

| Change                                                                                                            | Required review                                                                                                                                                |
| ----------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Documentation only                                                                                                | Independent documentation review, formatting, links and examples. Operational policy, command and configuration guidance also verifies its affected contracts. |
| Code or runtime configuration                                                                                     | Independent OCR standards and architecture review under [delegation](#open-code-review-delegation).                                                            |
| New package, public interface or cross-module ownership boundary, or an explicitly requested maintainability pass | The independent review above, followed by the [thermo-nuclear maintainability review](#thermo-nuclear-code-quality-review).                                    |
| Anything people see or hear in a maintained client                                                                | The applicable reviews above, followed by [design review](#design-review) of the affected screens and states.                                                  |

A documentation review checks the requested behavior, source ownership, scope,
examples and affected operational contracts. It uses reviewer-only sources when
needed to verify a requirement; it does not require product tests merely because
prose changed. Changes to OCR rules or selection configuration also validate
rule resolution through the delegation commands.

All review agents use `gpt-6.1-sol` with `high` reasoning and a fresh context.
Pass both settings explicitly. An unavailable required reviewer leaves that
review incomplete; implementer self-review does not replace it. Leave the
implementer's model, host defaults and saved OCR provider configuration unchanged.
OCR delegation needs no API key; the host performs the review with resolved rules.

After a fix, repeat the reviews whose conclusions the fix can invalidate. Review
the delta and its interactions, and record why any completed conclusions remain
valid. Retain the original task baseline and prior reports. An earlier report
cannot cover a later change merely because its original pass succeeded.

## Subagent model policy

When ChatGPT/Codex starts a subagent, select a GPT model explicitly. This applies
to implementation, review, research and other delegated work through native
subagent tools or T3 delegation, including nested delegation. Pass this policy
to each child agent. Skills and tool defaults must follow it.

The optional advisory [decision panel](#decision-panel) is the only exception. Keep its prescribed
`claude-fable-5-1`, `gpt-6.1-sol` and `gpt-6-astra` panelists; the Claude panelist
remains read-only and does not receive implementation or review work. Outside
that panel, ChatGPT/Codex must not start Claude or other non-GPT subagents.

Keep the required review model and reasoning settings above. If an eligible
GPT model is unavailable, report that delegation as blocked and continue
independent work; do not fall back to a non-GPT model.

## Reading responsibilities

The implementer reads the user request, originating issue or specification,
applicable `AGENTS.md` files, source code, topic vocabulary, and operational
guidance for setup, coding conventions, testing and delivery. For user-visible
work, this includes [DESIGN.md](../../DESIGN.md) and the Figma frames it links.
External API and framework references remain available for implementation.

Repository architecture documentation belongs exclusively to the review agent:

- `docs/architecture/`, including the reviewer-only architecture index.
- `docs/adr/` and any other architecture decision records.
- `.patterns/` and any other repository architecture guides.
- `.opencodereview/rule.json`, `.opencodereview/rules/` and resolved rule bodies,
  which contain architecture review instructions. Its routing `AGENTS.md` remains implementer-readable.
- `docs/research/`, `docs/qualification/`, and `docs/archive/` for technical design,
  qualification evidence and historical decisions.

The implementer never opens these files, including when a glossary, guide or
skill links to them or requests reading them. Repository-wide searches print
their contents too, so the implementer searches with
`scripts/implementer-grep` (`git grep` arguments, pathspecs after `--`). It
excludes every source above, plus committed review artifacts under
`artifacts/review-*`, which hold resolved rule bodies. Whole-commit searches are
supported; tree/blob selectors are rejected because they bypass root exclusions.
Pattern files (`-f`/`--file`), pagers (`-O`/`--open-files-in-pager`) and textconv
helpers are rejected because they can print excluded files. Pass patterns with `-e`.
Operational guides, coding conventions, vocabulary and product requirements are
separate files that the implementer can read in full. Keep architecture and design rationale in
`docs/architecture/` or ADRs rather than embedding them in implementer-facing
files. If a guide still mixes them, delegate its separation to the reviewer
before reading the architectural content.

Every active implementation requirement has one implementer-readable owner with
its host and release scope. Architecture and ADRs retain mechanisms, rationale
and historical decisions, and link to that operational contract. During extraction,
preserve the applicable requirement and scope in the operational owner. Reviewers
correct a missing operational requirement there rather than introduce it only as
a late review finding. Operational validation names every still-required release
check; qualification records retain the detailed evidence and unavailable status.

The reviewer owns architecture extraction and edits, updates links to moved
sections, and preserves every requirement and decision. Hand back actionable
outcomes and verification results without copying architecture documents into
the implementer's context. File separation supports this reading policy; it does
not itself restrict filesystem or Git-history access.

## Simplicity skills

The implementer must load and apply these repository-pinned skills before
implementation. The simplicity reviewer must independently do so before its
review. Use a catalogue entry when it resolves to the bundled copy; otherwise
read the linked `SKILL.md` files directly. No global installation or catalogue
refresh is required:

- [`ponytail`](../../.agents/skills/ponytail/SKILL.md): choose the smallest complete solution.
- [`principle-laziness-protocol`](../../.agents/skills/principle-laziness-protocol/SKILL.md): remove unnecessary layers and indirection.
- [`principle-subtract-before-you-add`](../../.agents/skills/principle-subtract-before-you-add/SKILL.md): remove unneeded complexity before adding code.

The copies come from `rajzik/agent-config` at the revision in
[`skills-lock.json`](../../skills-lock.json), the authoritative source for
reproducing these bundled files. That source repository is private; normal
implementation and review use the checked-in files without source-repository
access. Ponytail's bundled `UPSTREAM.md` preserves `agent-config`'s earlier import
from `DietrichGebert/ponytail`, including that original revision. Preserve the pins
and bundled licenses and provenance when updating them.

For framework or library research, also load `context7-mcp` when available and
use its documentation tools. If unavailable, consult official documentation and
installed source directly. Confirm APIs against the supported host/version.
Repository component selection, scope and safety requirements take precedence
over generic skill examples for both roles.

## Implementer handoff

1. Before editing, record `git status --short` and classify staged, unstaged and
   untracked changes as task-owned or unrelated. Select the task's existing
   same-repository PR branch against `main`, otherwise its existing task branch,
   otherwise a new branch from the latest `main`. Work in this checkout or an
   isolated worktree without moving unrelated edits. Record the starting commit;
   for existing task commits without completed review, use the merge-base with
   `main`. A fork PR head is a delivery blocker. A request forbidding merging
   makes an existing ready PR a draft before further work.
2. Identify acceptance criteria, [review depth](#review-depth) and relevant
   checks under the [testing policy](testing.md). Complete any required
   [design approval](#design-approval) before code edits.
3. Load and apply the [simplicity skills](#simplicity-skills) before implementation.
   For standard UI work, record the
   [component choice](native-components.md#choose-the-provided-implementation)
   before implementing, and exercise the smallest affected native journey before
   expanding the change. Implement and run the selected checks. Documentation
   changes use formatting, local links and any affected example, command or
   workflow contracts.
4. Pin the actual comparison and hand off first to a separate simplicity reviewer
   with explicit `model: "gpt-6.1-sol"`, `reasoning_effort: "high"` and `fork_turns: "none"`.
   Include the checkout, request and issue, acceptance criteria, original starting
   commit, summary, task-owned files, pre-existing changes, checks/results,
   limitations and [round history](#four-round-safeguard). For UI, include the
   selected API, remaining gaps and native evidence or deferred checks. Include
   prior findings, their dispositions and any completed review conclusions
   proposed for reuse.
   For uncommitted work, include staged/unstaged diffs and task-owned untracked
   files. A commit-only diff does not cover them. Give the simplicity reviewer
   the original starting commit and full task comparison. After its final report,
   hand the resulting snapshot, evidence and report to the independent
   documentation or OCR reviewer selected under [review depth](#review-depth).
   For OCR, create a local task snapshot after the simplicity pass and pass the
   exact checkpoint plan's `from`, `to`, mode, reason and prior report under
   [incremental checkpoints](#incremental-ocr-checkpoints). Snapshot commits are
   authorized before review; pushing still waits for the required reviews.
5. Pause implementer writes while a reviewer owns the checkout and wait for its
   final report before the next pass. Run applicable maintainability and design
   passes after the independent documentation or OCR review, giving each the
   original task comparison, evidence and earlier reports. Use the same explicit
   model, reasoning and fresh-context settings for every reviewer. Never run two
   writing reviewers at once. Record inapplicable passes with their reason,
   including design review when no client-visible behavior changed.
6. Apply the [review-depth rule](#review-depth) to later fixes and PR feedback.
   Identify invalidated conclusions explicitly. OCR reuse must satisfy its
   checkpoint helper; an unchanged valid checkpoint can reuse its completed
   report without an empty pass. Each new review sequence starts with a full-task
   simplicity pass. Other reviewers retain the original baseline and prior reports
   to assess the delta and affected interactions. Later-reviewer fixes return to
   the implementer for invalidation assessment and any required earlier passes
   before delivery. An unavailable or incomplete required pass blocks delivery.

A final report ends reviewer and child-agent write ownership. Reviewers do not
start PR watchers or schedules, and a notification does not renew ownership. Stop
any existing review watcher before returning the checkout. A later review starts
with a new pinned handoff. The implementer alone owns delivery and monitoring.

## Four-round safeguard

The implementer owns the review allowance. Apply it to initial implementation,
later fixes and PR babysitting. Keep the attempt number, rounds used, total task
rounds, findings and rethink history in the task issue and every reviewer handoff;
include the history in the PR description. Restore this record when resuming work
or changing agents, threads or worktrees.

### Count local review rounds

- One round is the simplicity pass and applicable independent, maintainability
  and design review sequence. Reusing a valid completed report still counts the
  sequence once; individual reviewers do not each consume a round.
- Record a round when its first reviewer begins substantive review. A failed,
  interrupted or partial round with substantive review counts. A retry that only
  repairs infrastructure, such as a reviewer failing to start, does not consume
  another round. Retain findings from interrupted rounds in the next handoff.
- If the fourth round satisfies every required review gate for the final
  artifact, continue delivery normally. If another round is needed after four
  rounds, perform the mandatory rethink below before starting it. Later-reviewer
  edits that need an earlier review repeated still require another round.
- A successful implementation review ends the attempt. Later PR feedback starts
  a fresh four-round allowance and retains the task's earlier history.

### Bound reviewer fix loops

Each reviewer may perform at most four unsuccessful internal fix-and-check
cycles in its pass. A cycle consists of applying fixes, running the relevant
checks and reviewing the corrected result. Count substantive failed or
interrupted cycles; infrastructure-only retries do not consume another cycle.
Carry the count into any replacement reviewer continuing that pass.

If the fourth cycle still leaves findings or failed checks, stop reviewer writes
and return an incomplete final report to the implementer. Include the cycle
count, attempted fixes, remaining findings and check results, and explicitly
request the mandatory rethink. This triggers the rethink even if fewer than four
outer rounds have run. A failed or incomplete OCR pass records no successful
checkpoint. A successful fourth cycle may complete normally.

### Mandatory rethink

Before further implementation edits or review after either limit is reached:

1. Record why the preceding rounds or cycles failed, including recurring
   findings, ineffective fixes and the assumptions behind the current approach.
2. Challenge those assumptions, consider an alternative approach, and write a
   revised plan explaining the concrete change in approach and the checks that
   will prove it resolves the failures. Preserve valid work and replace the parts
   responsible for the failures. Renaming the attempt or repeating the same
   patch-and-review loop does not satisfy this step. Use the
   [decision authority policy](#decision-panel) for unresolved choices, respecting the
   implementer's reading boundary and existing design approval requirements.
3. Implement the revised plan and run its relevant checks. Only then record a
   new attempt with a fresh four-round allowance and fresh reviewer cycle counts.
   Retain the original task baseline, all prior findings, total rounds and rethink
   history. Keep OCR checkpoint reuse subject to its existing validity rules.
4. Resume the required reviews in order. Apply this safeguard again if the
   revised approach exhausts its allowance. A rethink never waives review gates
   or authorizes delivery with unresolved findings.

## Reviewer responsibilities

1. Read applicable agent guides, the handoff and this workflow. Perform the
   documentation or OCR review selected under [review depth](#review-depth).
   For OCR, run [delegation](#open-code-review-delegation) for the actual comparison
   before reviewing. For documentation, check the affected source contracts,
   links, examples and policy consistency.
2. For OCR, apply the resolved repository rules as the architecture and standards
   checklist within that review pass, including their mandatory source-reading
   and scope/supersession checks. Architecture docs remain authoritative;
   resolving a rule is not evidence that its checks passed. The
   [reviewer-only coverage map](../architecture/open-code-review.md) records the
   migration of the former architecture checklist and source routing.
3. Review the selected task comparison against the requested behavior. For OCR,
   apply the resolved rules. An incremental range narrows changed-code coverage, not the
   context needed to assess it: inspect affected callers, invariants and
   collaborating modules, and verify prior findings against the new result.
   A full pass covers the entire task.
   Use the installed `code-review` guidance where applicable, with the handoff's
   actual comparison and specification. For OCR-excluded task-owned files, apply
   the same repository checklist through the appropriate artifact review.
   For React, React Native or Expo code, follow the
   [native skill selection](native-components.md#skills).
4. Independently validate each finding. Fix confirmed issues directly in the
   checkout, preserving unrelated work. Update affected tests and documentation,
   including architecture docs when needed. This assignment includes fixes,
   even when a review skill's default output is only a findings report.
5. Run the checks appropriate to the fixes, inspect the final diff, and review
   the corrected result again. Repeat until there are no unresolved issues within
   the authorized scope, subject to the
   [four-round safeguard's reviewer cycle limit](#bound-reviewer-fix-loops).
   Reviewer fixes remain within this review and do not spawn another
   implementation reviewer. Return control to the implementer when the cycle
   limit requires a rethink.
6. After a successful OCR pass, record its checkpoint when available under
   [incremental OCR checkpoints](#incremental-ocr-checkpoints). Every pass returns the
   reviewed comparison and file coverage, findings/dispositions, files changed,
   checks/results, unavailable checks, retained coverage and the
   [authorized decision](#decision-panel) for any finding that would change
   product scope or an architectural decision. Advisory votes do not authorize
   changing either merely to make an implementation pass.
   An OCR report also includes checkpoint or fallback, full/incremental mode and
   reason, OCR version, preview refs and applicable rule/source dispositions.
7. The final report ends reviewer and child-agent write ownership. Do not start
   PR watchers or recurring tasks in review threads. Stop any existing review
   watcher before reporting, and do not act on later PR notifications or resume
   writes without a new delegated review and explicit checkout handoff.

## Simplicity and reuse review

This first pass audits the full task diff and affected callers for unnecessary
custom mechanisms, speculative flexibility, duplicated framework behavior and
layers that add more work than they remove. It researches the smallest complete
solution before the independent documentation or OCR review checks the result.
It shares reviewer reading access, write ownership, finding validation and the
four-cycle limit.
It does not record an OCR checkpoint.

1. Load and apply the shared [simplicity skills](#simplicity-skills).
   Read the applicable requirements and reviewer-only architecture constraints
   before judging whether a mechanism is unnecessary.
   Apply the repository's component-selection and safety requirements over generic
   skill examples. Review documentation-only tasks for unnecessary procedure and
   duplication; research libraries when the task actually needs that capability.
2. For each material custom mechanism, check the standard library, platform,
   framework and already-installed dependencies first. Research current official
   documentation and source for the supported host/version. If those options have a
   concrete gap, check maintained, proven libraries before retaining custom code.
   Compare required behavior, compatibility and integration/maintenance cost;
   popularity alone does not prove suitability. Avoid a new dependency where
   direct code is simpler overall.
3. Prefer deleting unnecessary work or using a provided API over adding wrappers,
   generic frameworks or a new abstraction around the same complexity. Preserve
   required behavior, Draft safety, security, accessibility and host boundaries.
   Keep fixes within task scope; unrelated legacy debt belongs in existing or
   deduplicated follow-up issues, not a repository-wide rewrite.
4. For each finding, report the current mechanism, simpler alternative, linked
   primary evidence and version/host fit, what can be deleted, and the checks
   that establish preserved behavior. If research is unavailable or equivalence
   is unproven, record the limitation; do not claim a proven replacement.
   A no-change outcome is valid when the current solution is already simplest.
5. Validate and apply confirmed behavior-preserving fixes before handing off.
   For code fixes, resolve repository rules with `ocr delegate rule` for every
   file before fixing it, and honor the required architecture sources.
   Documentation fixes verify their affected operational contracts under
   [review depth](#review-depth). Follow [decision authority](#decision-panel)
   for product or architecture changes and [design approval](#design-approval)
   for visible design changes. Run relevant checks; return scope, sources,
   alternatives, findings and dispositions, deletions, final snapshot, checks and
   deferred work. The next independent documentation or OCR review covers the
   result, including these fixes.

## Thermo-nuclear code quality review

This separate maintainability pass applies only under [review depth](#review-depth).
Its reviewer has the same reading access, write ownership and final-report
boundary as the independent reviewer, with this pass in place of OCR delegation:

1. Read the global `thermo-nuclear-code-quality-review` skill's `SKILL.md` from
   the host's global skill install and follow it. The skill disables model
   invocation, so read the file instead of invoking it. If the skill is not
   installed, report the review as blocked.
2. On its first pass, review the full task diff from the original starting commit,
   including earlier fixes and task-owned uncommitted files. On a follow-up,
   review the changed range and interactions that can invalidate its previous
   conclusions, recording retained coverage. Review any scripts or configuration
   touched by documentation work; no code changed is a valid disposition.
3. Validate each finding and apply behavior-preserving fixes directly. Resolve
   rules with `ocr delegate rule` for every file the fixes touch and keep the
   result within those rules. A fix that would change product scope or an
   architectural decision follows [decision authority](#decision-panel).
4. Rerun the relevant checks and review the corrected result again. Return the
   reviewed scope, findings and their dispositions, files changed, checks and
   results, unavailable checks, and any panel outcomes.

## Design review

The design reviewer has the same responsibilities, reading access, write
ownership and final-report boundary as the OCR reviewer above, with this review
pass in place of the OCR delegation step. It applies to every task that changes
something people see or hear in a maintained client: screens, components,
styles, copy, icons, motion, notifications or accessibility labels.

1. Read [DESIGN.md](../../DESIGN.md) and the issue. Through the Figma MCP server,
   locate the frames for every changed screen and state in the
   [Unwired Mail — Design](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T)
   file on its macOS, iPadOS and iOS pages, in Light and Dark. Use the frames'
   screenshots as reference and their design context or variables for exact
   values.
2. Capture the implemented result for the same screens and states: the Mac host
   on a logged-in desktop, and iPhone and iPad on task-owned Simulators under the
   [native validation](native-validation.md) ownership rules, in Light and Dark
   and in each size class the design shows. Use mock mail sessions or fixtures
   that resemble the frames' content, and keep the captures with the task's results.
3. Compare the captures with the frames and DESIGN.md: layout and hierarchy,
   spacing and sizing, color tokens in both appearances, typography, SF Symbols,
   Liquid Glass placement, copy and truncation, states (empty, loading, error,
   selection, disabled) and accessibility (contrast, target sizes, labels).
   Platform differences that the frames show deliberately are not deviations.
4. Validate each deviation and fix confirmed ones within the task's scope
   directly in the checkout, then recapture. Resolve rules with
   `ocr delegate rule` for every file the fixes touch. Where a frame differs from
   a product requirement or feature guide, including the stale mockups DESIGN.md
   lists, the requirement governs: apply it and record a design follow-up. A fix
   that would change product scope, a state the design does not cover, or a
   conflict that documented authority does not resolve follows
   [decision authority](#decision-panel); list design follow-ups in the report.
5. When a capture target is unavailable, compare the changed code with the frames
   statically and record each missing capture as deferred. Missing Figma access
   leaves the design review blocked.
6. Return the reviewed scope, the frames compared (as links), capture paths,
   findings and their dispositions, files changed, checks and results, deferred
   captures, design follow-ups and any panel outcomes.

## Design approval

A request for visual design or redesign, or any change to how a maintained
client looks that the Figma frames do not already show, starts in Figma. Code
waits for the user's approval of the frames. Tasks that do not request visual
design or redesign may implement existing frames without another approval,
provided their visual design stays unchanged.

1. Read [DESIGN.md](../../DESIGN.md) and the issue. Through the Figma MCP server,
   in the
   [Unwired Mail — Design](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T)
   file, add or update the frames for every affected screen and state on the
   macOS, iPadOS and iOS pages, in Light and Dark, using DESIGN.md's tokens,
   the file's components and variables, and SF Symbols.
2. Ask the user to review: link each changed frame, summarize what changed and
   why, and list open questions. Stop and wait for the answer. This explicit design approval cannot be
   replaced by an advisory panel.
3. Apply requested changes in Figma and ask again. Start code only after the
   user explicitly approves, and record the approval and approved frame links
   in the issue and the PR description.
4. Implement against the approved frames; the [design review](#design-review)
   compares the result with them.

Missing Figma access blocks the task; report it instead of implementing
without approved frames.

## Decision panel

The implementer chooses reversible implementation details within the issue's
acceptance criteria and repository constraints. Record material assumptions and
the checks that verify them. An existing authorized requirement takes precedence
over a model's preferred approach.

Changes to product scope, user-visible behavior beyond the authorized request,
privacy guarantees or an accepted architectural decision need an explicit
authorized decision. A task that already authorizes that change does not require
another permission request. When authority is missing, present the concrete
choice to the owner and continue independent work while it is pending. Credentials,
accounts, devices and paid services are prerequisites, not decisions a vote can
supply. Explicit user limits, issue identification and claim takeovers stay with
the user. [Figma approval](#design-approval) remains required where applicable.

Use a read-only advisory panel only when requested or when a disputed technical
tradeoff cannot be resolved from code and requirements. The panel advises; its
votes alone do not change requirements or grant authority.

1. Give each panelist the same self-contained question, relevant constraints,
   concrete alternatives and consequences, with no conversation history and the
   implementer's reading boundary.
2. Delegate in parallel with explicit `high` reasoning to `claude-fable-5-1`,
   `gpt-6.1-sol` and `gpt-6-astra`. Keep the Claude panelist read-only. Each returns
   a recommendation and rationale, making no edits.
3. Set a bounded deadline. Record recommendations, disagreements, unavailable
   panelists and the chosen approach. Do not manufacture a consensus from failed
   or invalid responses. Model availability does not block a reversible choice
   already within the implementer's authority.

## Incremental OCR checkpoints

The OCR helper validates reuse of its completed coverage. The first OCR pass
covers the full task; subsequent passes cover changes since the last completed
snapshot. Simplicity reviews always cover the full task. Other reviews follow
[review depth](#review-depth), retaining the original baseline and reports when
assessing a later delta.

1. Fetch the PR's actual target base and use a stable task ID (normally its issue
   number) for every round on this branch. Commit only task-owned changes to a
   local snapshot before planning. Preserve unrelated work in its existing
   checkout and use a separate clean worktree if necessary. The helper rejects
   staged, unstaged and non-ignored untracked changes, and detached HEADs.
   Plan/report files belong under the Git directory, not in the task diff:

   ```sh
   review_dir="$(git rev-parse --absolute-git-dir)/ocr-review"
   mkdir -p "$review_dir"
   node scripts/ocr-checkpoint.mjs plan issue-123 origin/main > "$review_dir/plan.json"
   ```

   Replace `issue-123` and `origin/main` with the actual task and fetched target.
   Run from the repository root. Retain the original task starting commit for
   the other reviewers; do not replace it with the OCR checkpoint.

2. Pass the JSON plan to the OCR reviewer. It records immutable `from` and `to`
   commits, the target base, selection reason and previous completed report.
   Run OCR preview and rule resolution with those exact refs. Verify preview's
   merge base equals `from`. Review every selected file, related context and
   prior finding disposition. The report must distinguish carried-forward
   coverage from this round's newly reviewed range; a checkpoint never implies
   that CI or the other review passes have completed.

3. If the reviewer makes fixes, commit only those fixes locally, regenerate the
   plan and review the corrected range before completing. The prior checkpoint
   remains unchanged throughout. After all selected files and prior findings
   are accounted for, fixes are verified, required OCR checks succeed and no
   unresolved blocking findings remain, save the final report and run:

   ```sh
   node scripts/ocr-checkpoint.mjs complete "$review_dir/plan.json" "$review_dir/report.md"
   ```

   `complete` is the reviewer's attestation of successful coverage; the helper
   cannot judge a report's substance. It rejects an empty report, a dirty
   workspace, or any plan made stale by changes to HEAD, the base, policy or
   previous checkpoint. Never run it after a failed, interrupted, cancelled or
   partial review. Return the final report to the implementer and stop writes.

4. Checkpoints and their reports live in the repository's Git common directory,
   keyed by task ID and branch, so linked worktrees share them without adding
   files to commits. A new clone or renamed branch starts with a full review.
   Missing or malformed records, an unavailable/non-ancestor checkpoint, target
   base movement, or changes to review instructions and architecture sources
   cause a full review. The policy fingerprint covers tracked `AGENTS.md` files,
   `.agents/`, `.opencodereview/`, `.patterns/`, reviewer architecture/ADR/research/
   qualification/archive sources, `docs/agents/`, and the checkpoint helper.
   Changes to external skills, the requested behavior or other review inputs
   not in that fingerprint require `plan <task-id> <base-ref> --full`.
   Refresh the target base before each new round. Do not edit checkpoint files
   manually or use OCR's GitHub Action `incremental` option (comment
   deduplication) as a substitute for this range selection.

5. A plan with reason `unchanged` may reuse its completed OCR report only when
   the task's requirements and external review inputs are unchanged. Otherwise
   force a full review. An unavailable helper or an intentionally uncommitted
   review falls back to the full task plus workspace procedure below, records
   no checkpoint, and explicitly reports that incremental reuse is unavailable.
   Missing OCR itself still blocks the review. Never silently drop workspace
   changes to manufacture a clean snapshot.

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

1. Preview the requested scope using the checkpoint plan's exact `from`/`to`
   when available. Without a plan, preserve the handoff's original starting
   commit and review the full task.
   For task-owned staged, unstaged and untracked changes, use workspace mode:

   ```sh
   ocr delegate preview --format json
   ```

   For committed work, use the pinned starting commit and reviewed head:

   ```sh
   ocr delegate preview --format json --from <plan-from-or-starting-commit> --to <reviewed-head>
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

Deliver after the simplicity pass and all applicable later reviews cover the final
artifact, validated findings are resolved and relevant checks have passed or are
accurately recorded as unavailable. Required CI and release qualification remain independent gates.
Continue with [PR delivery and babysitting](pull-request-babysitting.md#implementer-pr-delivery)
within the user's explicit limits. Reviewers do not open or babysit PRs.
