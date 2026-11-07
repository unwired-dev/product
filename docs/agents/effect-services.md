# Define Effect services

Use this shape for Effect services that own an implementation, under the
repository's [Effect conventions](effect.md). Introduce services where callers
need a replaceable dependency. Keep values already owned by a closure as plain
values.

## Define the constructor and public methods

1. Extend `Context.Service<ServiceName>()` with a stable
   `@private-email/<package>/<Name>` identifier.
2. Pass `{ make: Effect.gen(function* () { ... }) }` to the service definition.
   Acquire dependencies with `yield*` inside `make`, before defining methods.
3. Define reusable operations inside `make` with `Effect.fn('Service.method')`.
   Use `Effect.fnUntraced` where the operation needs no tracing span.
4. Keep helper operations private to the constructor closure. Return only the
   public methods as an object with `as const`. Let `Context.Service` infer the
   service shape from that object.
5. Add `public static readonly layer = Layer.effect(this, this.make)` to the
   service class. Document the dependencies required to build that layer.

`SyntheticGoogle` in `packages/mail-core/src/testing/synthetic-gmail.ts` follows
this shape: it acquires the `SyntheticScenario` contract
(`packages/mail-core/src/testing/synthetic-relay.ts`) in `make`, defines its
methods with `Effect.fn('SyntheticGoogle.…')`, keeps `historyPage` private and
returns its public methods `as const`.

## Keep types inferred

Use the constructor's inferred return type for an implemented service. Obtain
its public type through `SyntheticGoogle['Service']` when another API needs that type.
Use an explicit service shape for a dependency contract that has no constructor
implementation, as `SyntheticScenario` does.

Keep `as const` for the returned object's readonly inference. Avoid assertions
that force an implementation into a separately declared service interface.
Let method success, error and environment types flow from the Effects they call.

## Compose dependencies through layers

Keep `make` as an Effect that constructs the service, and `layer` as the Layer
that installs it. Dependencies are acquired during construction and captured by
the methods.

Provide dependency layers with `Layer.provide` at the composition boundary, as
`syntheticRegistrationLayer` in
`packages/mail-core/src/testing/synthetic-registration.ts` does.
Use `Layer.provideMerge` when the composed layer must expose its dependencies
alongside the service. In tests, supply controlled dependency implementations
with `Layer.succeed` and exercise the real service's public methods.

Run Effects at the existing host or handler boundary under the
[runtime conventions](effect.md#running-programs). Keep runtime creation and
`Effect.run*` calls out of service methods.

Errors, logging, imports and `Effect.fn` combinators follow
[Effect conventions](effect.md#errors). Preserve typed failures unless the
operation's contract explicitly permits recovery, and keep fallback and
partial-success behavior specific to the operation's requirements.
