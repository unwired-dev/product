---
status: accepted
---

# Scope Effect adoption

[ADR 0003](0003-typescript-effect-convex-backend.md) chose TypeScript with Effect
for explicit error, dependency, and async workflow handling, but did not define
where Effect applies. By 2026-10-01, only the shared mail core used it. The
Convex backend parsed provider responses and request bodies with hand-rolled
guards, and stores discarded failure causes.

Use Effect where its guarantees matter:

- Decode every untrusted boundary with `Schema`: native bridge results, HTTP
  bodies, provider responses, tokens, persisted JSON, and configuration selectors.
- Write shared application logic in `packages/mail-core` as Effect programs behind
  framework-independent stores, so hosts stay plain React.
- Run Convex actions that call external services as Effect programs, with tagged
  retryable and terminal errors.

Convex queries and mutations stay on Convex validators and plain TypeScript. They
are deterministic transactions, and Convex already supplies their argument
validation and atomicity. The legacy mail test harness keeps no package
dependencies until cutover retires it.

[Effect conventions](../agents/effect.md) define the patterns. Shared lint policy
enforces them. Each exemption names the issue that removes it.

## Declarative wire schemas in contracts

The #1049 review decision panel selected permitting `effect/Schema` in
`packages/contracts` solely for declarative wire validators and inferred types.
Keep those schemas in dedicated entry points, separate from Convex validators;
contracts still owns no application logic, services, transports or Effect execution.
The client and receiver share one payload inventory instead of duplicating it in
mail-core and Convex. No product requirement or other dependency boundary changed.

Consequences: runtime consumers of the schema entry point include `effect/Schema`;
type-only imports from the reporting types entry point are erased and add no
runtime dependency. Keep the reporting types inferred from the canonical schemas
so callers cannot use a second, weaker payload inventory. Other contracts entry
points retain their existing dependencies. The decision record is linked from
[issue #1049](https://github.com/unwired-dev/product/issues/1049#issuecomment-6252212464).

Privacy and security: the receiver decodes with these schemas and rejects excess
fields before projecting reports for PostHog. Changes to admitted fields, literals
or bounds require privacy review because they can widen the outgoing inventory.
The native projection and receiver projection remain independent enforcement
boundaries; schema admission does not authorize forwarding unchecked input.
