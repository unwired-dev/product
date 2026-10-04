# Open Code Review routing

`rule.json` contains repository architecture review instructions. It is
reviewer-only under the [implementation and review workflow](../docs/agents/implementation-review.md).
Implementers may read this routing file but must not open the rule config or
print resolved rule bodies into their context. The review agent owns rule edits
and validation; operational results can be returned without copying the rules.
