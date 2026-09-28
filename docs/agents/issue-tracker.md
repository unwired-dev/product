# Issue tracker: GitHub

Issues and PRDs live in GitHub Issues for `unwired-dev/product`.
Use the GitHub CLI for creating, reading, updating, labelling, and closing issues.

Pull requests are not a triage request surface.

When publishing tickets, use native GitHub blocking dependencies where available,
falling back to a "Blocked by" reference in the issue body.

## Triage labels

Use the repository's existing readiness labels:

| Role                 | GitHub label      |
| -------------------- | ----------------- |
| Ready for an agent   | `ready-for-agent` |
| Ready for a human    | `ready-for-human` |
| Will not be actioned | `wontfix`         |

Check `gh label list --repo unwired-dev/product` before applying labels. Explain
missing information or blockers in the issue; do not assume `needs-triage` or
`needs-info` exists. Use native blocking dependencies for relationships between
issues, rather than encoding dependencies in labels.
