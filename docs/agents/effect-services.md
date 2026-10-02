# Define Effect services

Use this shape for Effect services that own an implementation. It follows the
supplied Jira example and the repository's [Effect conventions](effect.md).
Introduce services where callers need a replaceable dependency. Keep values
already owned by a closure as plain values.

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

The following self-contained illustration uses the Jira names from the supplied
example. `JiraHttpClient` and `JiraConfig` define dependency contracts. `Jira`
contains the implementation. Replace the `example` namespace with the owning
package when applying the pattern.

```ts
import * as Context from 'effect/Context';
import * as Effect from 'effect/Effect';
import * as Layer from 'effect/Layer';
import * as Schema from 'effect/Schema';

export class JiraError extends Schema.TaggedError<JiraError>()('JiraError', {
  reason: Schema.Literals(['NotFound', 'NotUnique']),
  message: Schema.String,
}) {}

export class JiraHttpClient extends Context.Service<
  JiraHttpClient,
  {
    readonly create: (
      summary: string,
      assignee: string,
    ) => Effect.Effect<string, JiraError>;
  }
>()('@private-email/example/JiraHttpClient') {}

export class JiraConfig extends Context.Service<
  JiraConfig,
  { readonly defaultAssignee: string }
>()('@private-email/example/JiraConfig') {}

export class Jira extends Context.Service<Jira>()(
  '@private-email/example/Jira',
  {
    make: Effect.gen(function* () {
      const jiraHttpClient = yield* JiraHttpClient;
      const { defaultAssignee } = yield* JiraConfig;

      const createIssue = Effect.fn('Jira.createIssue')(function* (
        summary: string,
      ) {
        return yield* jiraHttpClient.create(summary, defaultAssignee);
      });

      const createIssues = Effect.fn('Jira.createIssues')(function* (
        summaries: ReadonlyArray<string>,
      ) {
        return yield* Effect.forEach(summaries, createIssue, {
          concurrency: 2,
        });
      });

      return { createIssues } as const;
    }),
  },
) {
  /** Constructs Jira. Consumers provide JiraHttpClient and JiraConfig. */
  public static readonly layer = Layer.effect(this, this.make);
}
```

## Keep types inferred

Use the constructor's inferred return type for an implemented service. Obtain
its public type through `Jira['Service']` when another API needs that type.
Use an explicit service shape for a dependency contract that has no constructor
implementation, as the two dependency tags above demonstrate.

Keep `as const` for the returned object's readonly inference. Avoid assertions
that force an implementation into a separately declared service interface.
Let method success, error and environment types flow from the Effects they call.

## Compose dependencies through layers

Keep `make` as an Effect that constructs the service, and `layer` as the Layer
that installs it. The example's `Jira.layer` requires `JiraHttpClient` and
`JiraConfig`. Those dependencies are acquired during construction and captured
by the methods.

Provide dependency layers with `Layer.provide` at the composition boundary.
Use `Layer.provideMerge` when the composed layer must expose its dependencies
alongside the service. In tests, supply controlled dependency implementations
with `Layer.succeed` and exercise the real service's public methods.

Run Effects at the existing host or handler boundary under the
[runtime conventions](effect.md#running-programs). Keep runtime creation and
`Effect.run*` calls out of service methods.

## Apply the repository's error and logging rules

Define domain failures with `Schema.TaggedError`. Preserve typed failures unless
the operation's contract explicitly permits recovery. Keep fallback and
partial-success behavior specific to the operation's requirements.

Use Effect's logging and annotation APIs. Follow the
[error and privacy rules](effect.md#errors) for diagnostic fields. Record fixed
operation names and allow-listed codes. Raw request payloads, responses and
`error.toString()` are not safe diagnostic fields for mail operations.

Use namespace imports from Effect module subpaths throughout, including
`import * as Result from 'effect/Result'` when an operation uses `Result`.
Pass additional behavior as combinator arguments to `Effect.fn`, as required by
the [function conventions](effect.md#functions-and-services).
