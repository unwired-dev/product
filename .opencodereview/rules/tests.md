Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to test code: TypeScript, Swift and script tests, their fixtures and the native test projects.

`docs/agents/testing.md` is the policy: integration and E2E by default, a test admitted only for a named behavior or failure risk, and mocked journeys kept distinct from real integration evidence. Review a test for whether it can fail for the defect it claims to guard.

#### The test proves the behavior

- A provider-action journey such as `InboxTests.registrationJourney` or `WindowTests.registrationJourney` treating optimistic controls, the encrypted cache or a done notice as provider confirmation. Check each action before later notices can mask refusal, rule out unfinished saving/sync and retry/authentication/rejected/blocked outcomes, and label synthetic completion proxies separately from provider-side label/readback evidence; otherwise a guarded or unsent write can leave pending intent behind a passing journey.
- An assertion that cannot fail for the regression in question: it asserts the fixture, a mock's return value, a call count or call order, or mirrors the implementation line by line. Ask what plausible defect would turn it red.
- The collaboration under test replaced by a mock. Substitute only the external boundary (provider response, native module, clock); stores, Effect services and layers, and Convex functions run for real.
- A store or Convex function tested through an internal helper rather than its public interface (`getSnapshot`/`subscribe`/actions, or the registered function against the test database and identity context).
- A changed behavior covered only on its success path when the change adds a failure, cancellation, conflict or recovery path.
- A bug fix with neither a regression test that fails without the fix nor a documented reason automation is unavailable, as permitted by `docs/agents/testing.md`.
- A test whose name states a risk it does not exercise, or a new test with no nameable risk: a trivial accessor, a constant, framework behavior, or one more permutation of a contract already covered at another layer.

#### Privacy and security cases stay covered

- A test for authorization, account or connection isolation, encryption, key safety, data loss or duplicate delivery removed, skipped, weakened or rewritten to assert less, without the pull request naming the retained coverage or why the risk is gone.
- A Convex test that never calls the function as an unauthenticated caller, as a different account, or with a malformed argument when the function guards account data.
- A fixture containing a real email address, token, key or message. Fixtures are synthetic.

#### Determinism and isolation

- A synthetic Gmail metadata projection that drops a requested admission header,
  such as Content-Disposition, while a prefetch regression asserts only the final
  cache entry. Match the provider's requested-header projection and check that
  excluded parts never receive a speculative full-body request; otherwise the
  test can pass after downloading the content it claims to exclude.

- A wait on a sleep, a timeout or scheduler ordering where a controlled clock, explicit synchronization or an observable state change is available. A test that needs a timeout to pass is hiding a race.
- An absence check ("nothing happened") that passes because it did not wait long enough.
- State shared between tests: a module-level store, a reused database, a global mock or environment variable not restored, a Keychain service or Simulator not owned by the run.
- Dependence on the network, the wall clock, locale, time zone or test order.
- An Effect-returning API tested by calling `Effect.runPromise` by hand rather than `@effect/vitest` (`it.effect`, `layer`) with controlled layers.

#### Evidence is labelled honestly

- A rendered component test, a Mock Mail Session journey, a runner contract test with tool stubs, or a Hermes export described as native E2E, provider, persistence or device evidence. Each proves only what it exercised.
- A native runner that reports success with zero selected tests, reuses a shared Simulator by name, or leaves owned devices, DerivedData or temporary directories behind on failure, cancellation or timeout.
- A mock scenario that accepts anything but a fixed scenario name, or test-only code reachable from a production build.
- A check that could not run recorded as passing rather than deferred.

#### Leave to tooling

Vitest and Jest style rules, formatting, unused variables and type errors. `**/*.test.ts` and `**/*.test.tsx` are exempt from the `JSON.parse`, `typeof` guard and untagged-error lint rules by the documented, tracked exemption in the lint configurations; do not extend that exemption to other test/fixture names or languages. The merged Swift rule covers Swift test mechanics; this file's policy takes precedence where they differ.
