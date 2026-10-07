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
| Will not be actioned   | `wontfix`         |
| Claimed by active work | `in progress`     |

Check `gh label list --repo unwired-dev/product` before applying labels. Explain
missing information or blockers in the issue; do not assume `needs-triage` or
`needs-info` exists. Use native blocking dependencies for relationships between
issues, rather than encoding dependencies in labels.

Add `in progress` when implementation starts and remove it when that work ends,
whether or not it delivered. A crashed run can leave a stale claim that agents
keep skipping; a person clears it by removing the label or by explicitly asking
an agent to take the issue over. Agents skip issues claimed by other work, so the label helps prevent
duplicate work; the [implement-issue skill](../../.agents/skills/implement-issue/SKILL.md)
owns the claim procedure.
