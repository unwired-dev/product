# Issue tracker: GitHub

Issues and PRDs live in GitHub Issues for `unwired-dev/product`; manage them with `gh`.

Put triage questions on the issue, not the PR.

When publishing tickets, use native GitHub blocking dependencies where available,
falling back to a "Blocked by" reference in the issue body.

## Triage labels

Use the repository's existing labels:

| GitHub label       | Meaning                                                         |
| ------------------ | --------------------------------------------------------------- |
| `ready-for-agent`  | Ready for an agent                                              |
| `ready-for-human`  | Ready for a human                                               |
| `ready-for-test`   | Merged; awaiting a person testing a released build              |
| `human needed`     | A person must act before the PR merges or the issue completes   |
| `priority: high`   | Work first: core mail reliability, safety, foundations, release |
| `priority: medium` | Planned feature or improvement                                  |
| `priority: low`    | Deferred expansion, optional experiment or maintenance          |
| `wontfix`          | Will not be actioned                                            |
| `in progress`      | Claimed by active work                                          |

When only human work remains, replace `ready-for-agent` with `ready-for-human`,
or with `ready-for-test` when only testing a released build, such as a TestFlight
one, remains. Comment what remains, including what to test.

Apply only labels `gh label list --repo unwired-dev/product` shows; explain
missing information or blockers in the issue.

Claim an issue with `scripts/issue-claim claim <issue>` when implementation
starts, and release it with `scripts/issue-claim release <issue> --outcome <outcome>`
when that work ends, delivered or not. Skip issues claimed by other work unless
asked to take one over (`--takeover`). Partial delivery claims only the
sub-issue it implements.
