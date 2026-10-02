# Implementation and review

Every implementation hands off to a separate code review agent before delivery.
The review agent always uses `gpt-6.1-sol` with `high` reasoning, regardless of
the implementer's model or reasoning effort. Pass both settings explicitly.
If that configuration or agent spawning is unavailable, report the review as
blocked. An implementer self-review or a different model does not satisfy it.

## Reading responsibilities

The implementer reads the user request, originating issue or specification,
applicable `AGENTS.md` files, source code, topic vocabulary, and operational
guidance for setup, coding conventions, testing and delivery. External API and
framework references remain available for implementation.

Repository architecture documentation belongs exclusively to the review agent:

- `docs/architecture/`, including the reviewer-only architecture index.
- `docs/adr/` and any other architecture decision records.
- `.patterns/` and any other repository architecture guides.
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
   and their results, and known limitations. Tell it to read this workflow and the
   relevant architecture docs, review the implementation, fix validated issues,
   and rerun the relevant checks. Include the actual comparison to review:

   - For uncommitted work, inspect the staged and unstaged diffs and task-owned
     untracked files. A commit-only diff does not cover this work.
   - For committed work, pin the starting commit or merge-base and inspect the
     full task diff, plus any task-owned uncommitted files.

4. Pause all implementer writes to the shared checkout while the reviewer owns
   it. Wait for the reviewer's final report. Additional implementation edits,
   including fixes after review or PR feedback, require another pinned review.

## Reviewer responsibilities

1. Read applicable agent guides, the
   [architecture index](../architecture/README.md), [domain policy](domain.md), and architecture
   docs relevant to the changed behavior. Read ADR 0059 through 0064 for replacement
   scope and dependencies, plus affected earlier or later decisions. Their
   replacement decisions take precedence where they supersede prototype behavior.
   Historical prototype plans do not expand the approved scope.
2. Review the entire task against both its requested behavior and the repository's
   architecture and coding standards. Use the installed `code-review` guidance
   where applicable, with the handoff's actual comparison and specification.
   Check collaborating modules, privacy boundaries and test coverage as needed.
3. Independently validate each finding. Fix confirmed issues directly in the
   checkout, preserving unrelated work. Update affected tests and documentation,
   including architecture docs when needed. This assignment includes fixes,
   even when a review skill's default output is only a findings report.
4. Run the checks appropriate to the fixes, inspect the final diff, and review
   the corrected result again. Repeat until there are no unresolved issues within
   the authorized scope. Reviewer fixes remain within this review and do not
   spawn another implementation reviewer.
5. Return the reviewed scope, findings and their dispositions, files changed,
   checks and results, unavailable checks, and any unresolved blocker requiring
   a user decision. Do not silently alter product scope or architectural decisions
   to make an implementation pass.

## Completion

The implementer delivers only after the required reviewer has finished fixing
validated issues and verifying the final artifact. Unresolved findings or an
unavailable reviewer leave implementation review incomplete; report them
accurately. Review completion and required CI remain independent gates.
For PR work, also follow the existing
[PR babysitting policy](pull-request-babysitting.md).
