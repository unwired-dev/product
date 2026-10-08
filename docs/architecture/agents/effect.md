# Effect: architecture notes

Reviewer-only companion to [docs/agents/effect.md](../../agents/effect.md).
Read under the [implementation and review workflow](../../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Boundaries

At the native bridge, the Apple host owns its security checks: Keychain access,
encryption, file locking, provider authorization, and the codes it rejects with.
TypeScript decodes what crosses the bridge so a malformed or unexpected result
fails closed; it complements the host's checks and never replaces them.

## Running programs

`mail-core/composer-navigation` is a framework-independent coordinator for a
host-provided finishing callback. Like `mailboxes.ts.savedMessageBodies`, it
composes Promise-returning host actions with plain async code; the underlying
stores keep their single Effect run. Each Inbox provider owns one coordinator.

Convex handlers run their program with `runConvexProgram` from
`packages/convex/convex/effectRuntime.ts`. It reads each configuration key from
Convex's `env` when loaded, because the default runtime's environment cannot be
enumerated or copied, as `ConfigProvider.fromEnv` requires. It logs to
`console.error` so Convex records failures at error level, and it resumes sleeps
through a Promise so Convex calls stay in the function's async context. Convex code
calls `fetch` through `Effect.tryPromise` rather than `HttpClient`, which keeps
fetch's abort deadlines and test fetch mocks.
