# Implementation and review

Every implementation hands off to a separate code review agent before delivery.
The review agent always uses `gpt-6.1-sol` with `high` reasoning, regardless of
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
- `.opencodereview/rule.json` and resolved rule bodies, which contain architecture
  review instructions. Its routing `AGENTS.md` remains implementer-readable.
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

1. Before editing, record the starting commit, `git status --short`, and any
   existing staged, unstaged or untracked changes. Preserve unrelated work.
2. Implement the requested behavior and run the relevant checks under the
   [testing policy](testing.md). Documentation changes use formatting and local
   link checks.
3. Spawn the reviewer with these explicit arguments:

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

4. Pause all implementer writes to the shared checkout while the reviewer owns
   it. Wait for the reviewer's final report. Additional implementation edits,
   including fixes after review or PR feedback, require another pinned review.

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
   checks and results, unavailable checks, and any unresolved blocker requiring
   a user decision. Do not silently alter product scope or architectural decisions
   to make an implementation pass.

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
describes first-match resolution and `merge_system_rule`. This repository uses
one common rule with conditional sections and merges embedded language rules.
Its targeted includes admit owned documentation and tests; explicit excludes
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

   Confirm every task-owned path resolves the project checklist together with
   its embedded rule. Use `ocr rules check <path>` to inspect the selected source
   and pattern when needed, keeping rule bodies in the reviewer context. A
   missing, invalid or overridden repository checklist leaves this step
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

## Completion

The implementer delivers only after the required reviewer has finished fixing
validated issues and verifying the final artifact, including the Open Code Review
delegation step. Unresolved findings or an
unavailable reviewer leave implementation review incomplete; report them
accurately. Review completion and required CI remain independent gates.
For PR work, also follow the existing
[PR babysitting policy](pull-request-babysitting.md).
