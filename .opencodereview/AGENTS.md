# Open Code Review routing

`rule.json` maps repository paths to the review rules under `rules/`. Both
contain repository architecture review instructions and are reviewer-only under
the [implementation and review workflow](../docs/agents/implementation-review.md).
Implementers may read this routing file but must not open the rule config, the
rule files, or print resolved rule bodies into their context. The review agent owns rule edits
and validation; operational results can be returned without copying the rules.

The rules improve over time. Hand validated pull-request review feedback, escaped
defects and false-positive findings to the reviewer as
[rule-improvement candidates](../docs/agents/implementation-review.md#improve-the-review-rules).
