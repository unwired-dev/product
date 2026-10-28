# Issue tracker: GitHub

Issues and PRDs live in GitHub Issues for `unwired-dev/product`.
Use the GitHub CLI for creating, reading, updating, labelling, and closing issues.

Pull requests are not a triage request surface.

When publishing tickets, use native GitHub blocking dependencies where available,
falling back to a "Blocked by" reference in the issue body.

## Triage labels

Use the repository's existing readiness labels:

| Role                   | GitHub label      |
| ---------------------- | ----------------- |
| Ready for an agent     | `ready-for-agent` |
| Ready for a human      | `ready-for-human` |
| Ready for device test  | `ready-for-test`  |
| Will not be actioned   | `wontfix`         |
| Claimed by active work | `in progress`     |

Use `ready-for-test` in place of `ready-for-agent` or `ready-for-human` when the
implementation is merged and only a person testing a released build, such as
one distributed through TestFlight, remains. Comment on the issue with what to
test.

Check `gh label list --repo unwired-dev/product` before applying labels. Explain
missing information or blockers in the issue; do not assume `needs-triage` or
`needs-info` exists. Use native blocking dependencies for relationships between
issues, rather than encoding dependencies in labels.

Add `in progress` when implementation starts and remove it when that work ends,
whether or not it delivered. A crashed run can leave a stale claim that agents
keep skipping; a person clears it by removing the label or by explicitly asking
an agent to take the issue over. The daily
[Stale claims workflow](../../.github/workflows/stale-claims.yml) runs
`scripts/stale-claims`, which flags such claims: an open `in progress` issue
with no open pull request closing it or from its claim branch, and no commit on
that branch, for `STALE_CLAIM_DAYS` days (a repository variable, default 3). It
dates a claim by its `scripts/issue-claim` comment, or by when the label was
added when no claim comment remains, comments once per claim and never removes
the label. Agents skip issues claimed by other work, so the label helps prevent
duplicate work. Work that delivers only part of an issue applies `in progress`
only to the sub-issue it implements and leaves it off the parent. The
[implement-issue skill](../../.agents/skills/implement-issue/SKILL.md) owns
claiming and parent updates, through `scripts/issue-claim`.
