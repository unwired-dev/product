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
