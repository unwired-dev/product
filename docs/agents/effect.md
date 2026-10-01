# Effect conventions

These conventions apply the installed Effect guide (`node_modules/effect/AGENTS.md`)
to this repository. [ADR 0065](../adr/0065-scope-effect-adoption.md) records
the scope. Read the installed guide first. A fresh worktree has no `node_modules`;
run the [install](../../README.md#local-development) before reading it.

## Where Effect is required

| Code                                                                                                                | Effect use                                                                                                     |
| ------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Every untrusted boundary: native bridge results, HTTP bodies, provider responses, tokens, persisted JSON, selectors | Decode with `Schema`                                                                                           |
| Shared application logic in `packages/mail-core`                                                                    | Effect programs behind a host-facing store                                                                     |
| Convex actions that call external services                                                                          | Effect programs, run once in the handler                                                                       |
| Convex queries and mutations                                                                                        | Convex validators for arguments; `Schema` for embedded unknown payloads                                        |
| React components and hooks                                                                                          | Plain TypeScript consuming stores through `useSyncExternalStore`                                               |
| `packages/mail-test-harness`                                                                                        | None; this legacy prototype harness is retired at [cutover](https://github.com/unwired-dev/product/issues/627) |

## Boundaries

Decode `unknown` input with `Schema.decodeUnknownEffect`, or with
`Schema.decodeUnknownOption`/`Schema.is` where only a branch is needed. Decode JSON
text with `Schema.fromJsonString(schema)`. Narrow with the `Predicate` module when
no schema is warranted. A failed decode keeps the boundary closed: map it to the
boundary's existing error, with the decode error as its cause.

At the native bridge, the Apple host owns its security checks: Keychain access,
encryption, file locking, provider authorization, and the codes it rejects with.
TypeScript decodes what crosses the bridge so a malformed or unexpected result
fails closed; it complements the host's checks and never replaces them.

## Errors

Define failures with `Schema.TaggedError`. A failure that wraps a foreign error
carries it as `cause: Schema.Defect()`, so recovery can inspect the original
error. Recover with `Effect.catchTag` or `Effect.catchTags`. Expected states, such
as locked storage or a cancelled sign-in, are their own tagged errors and recover
quietly. Unexpected failures are logged with `Effect.logError(message, diagnostic)`
before recovery.

Logs carry no mail content, tokens, or account identifiers. Any field of a host
or provider error can contain them, so a failure keeps its cause for handling and
logs an allow-listed diagnostic instead: a known native error `code` or standard
error `name`, a fixed fallback for anything else, and for decode failures only
the failing paths. See `packages/mail-core/src/diagnostics.ts`.

## Functions and services

Write inline programs with `Effect.gen`. Name reusable functions with
`Effect.fn('Name')` at a useful tracing boundary, otherwise `Effect.fnUntraced`.
Add behavior with combinators passed to `Effect.fn`, not `.pipe` on it.

Introduce a `Context.Service`, keyed `@private-email/<package>/<Name>` with a static
`layer`, when callers need to substitute an implementation: a provider, HTTP client,
clock, or configuration. A value already held in a closure stays a plain value.

## Running programs

Run Effect at the edge: one `Effect.runPromise` per host-facing call, such as a
store method or a Convex handler. Create a `ManagedRuntime` only for a Layer with
dependencies or resources, and dispose it with its owner. Serialize shared mutable
work with `Semaphore`; use `withPermitsIfAvailable` to drop overlapping requests.

Inside Effect code, use Effect's services instead of globals: `Effect.log*` for
logging, `Clock` and `DateTime` for time, `Config` for environment values,
`HttpClient` for HTTP, and `Schedule` for retries and polling.

Hosts consume shared logic as framework-independent stores:
`getSnapshot`, `subscribe`, and Promise-returning actions. See
`packages/mail-core/src/persistent-inbox.ts` and `registration.ts`.

## Tests

Test stores and Convex functions through their public interfaces, as the
[testing policy](testing.md) requires. Test an exported Effect-returning API with
`@effect/vitest` (`it.effect`, `layer`), adding it as a development dependency at
the first such test.

## Enforcement

`scripts/oxlint-effect-policy.ts` applies to the root, mobile, and Mac lint
configurations:

- Effect `recommended` rules, plus the rules that reject console, time,
  randomness, `fetch`, timers, `process.env`, and JSON globals inside Effect code.
- `effect-boundaries/no-object-typeof-guard` and `effect-boundaries/no-json-parse`
  reject hand-rolled parsing, and `effecttsgo/extends-native-error` rejects
  untagged error classes. Tests and the legacy harness are exempt.
- `effect-imports/namespace-imports` requires
  `import * as Module from 'effect/Module'`.

`pnpm test:tooling` checks the custom rules in every configuration.
