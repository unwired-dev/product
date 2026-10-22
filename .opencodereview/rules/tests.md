Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to test code: TypeScript, Swift and script tests, their fixtures and the native test projects.

`docs/agents/testing.md` is the policy: integration and E2E by default, a test admitted only for a named behavior or failure risk, and mocked journeys kept distinct from real integration evidence. Review a test for whether it can fail for the defect it claims to guard.

#### Regression boundary fidelity

- A package test such as `packages/mail-core/test/rich-reader.test.ts` adding a
  relative `../src/` import even when its target is an exported entry point.
  Check the specifier against `packages/README.md` and the package's `exports`;
  use the package-name entry point, such as `@private-email/mail-core/theme`,
  while preserving relative imports between source files and to owned test
  fixtures. Otherwise tests bypass package export resolution and depend on the
  source layout. Boundary lint currently checks the destination for own-package
  tests and can accept this case, so a passing lint run does not establish that
  the import follows the package-name convention.

- A lifecycle test such as `AccountRemovalTests` replacing the production removal
  callback with a lower-level consent call. Exercise the same callable boundary as
  the host, including its withdrawal retry, and preserve credential-custody
  assertions; otherwise the tested substitute can pass while production breaks.
- `reporting-artifacts.test.mjs` or another direct tooling test calling `mkdtemp`
  under ignored `scratchpad/` before creating that parent. Each independently run
  journey must own/create its prerequisites and clean its child on failure;
  otherwise a fresh checkout fails before exercising the claimed contract.

#### The test proves the behavior

- Negative subprocess cases such as the evidence-validator matrix in
  `scripts/mock-mail-runner.test.mjs` asserting only a nonzero exit. Require the
  owning rejection diagnostic as well, distinguishing failed checks from malformed
  evidence; otherwise a syntax error, missing dependency or unrelated crash can
  satisfy every rejection case without exercising the intended guard.

- A layout regression journey such as `InboxTests.verifyCompactInboxHeader`
  checking only the title against Back when the reported header also includes a
  subtitle. Assert the required geometry for every named part at entry and after
  the relevant navigation transition; otherwise a displaced subtitle can pass
  while the reported regression remains possible. Match locators to the rendered
  text and accessibility exposure, including variable counts.

- A transition test such as the Profile-move cases in
  `packages/mail-core/test/outbox.test.ts` checking only downstream delivery or
  preservation. Assert the transition through the resulting public snapshot as
  well as its consequences; a helper callback or spy alone proves no state
  change. Otherwise an untriggered move can leave ordinary delivery passing
  while the claimed ownership-change regression is untested.

- A native journey locator such as `WindowTests.key(groups:in:)` retaining a
  text pattern after its host changes displayed grouping, whitespace, copy or
  accessibility exposure. Compare every affected locator and caller with the
  rendered producer, including `account-settings.tsx.PrivateSync`, and the
  native element type and label-versus-value contract. Scope a sheet choice to
  its sheet when labels repeat; selecting the last global `Reply` match can
  activate the reader toolbar behind the sheet. Preserve matching for other
  formats sharing the helper, such as hyphenated Recovery Keys beside
  space-separated Enrollment Codes; otherwise the packaged journey cannot find
  its target despite passing component tests. Record unavailable native
  execution separately from static or predicate-only evidence.

- A native keyboard-visibility check such as `InboxTests.appleRegistrationJourney`
  comparing only a result's bounds with the keyboard. Require the complete result
  inside its scroller's visible rectangle and enough viewport height for a full
  touch row, then inspect the native capture. Exercise required list gestures
  while the keyboard stays present. An element can lie above the
  keyboard while its scroller clips it, so a boundary-only assertion can falsely
  qualify an unreadable result or unreachable destination.

- A Draft editor keyboard regression in `packages/draft-editor/test/editor.test.ts` invoking a command that replays only document steps while the real key handler dispatches a caret change. Exercise the page's keydown handlers and subsequent typing as well as its posted semantic body; otherwise a passing document-only assertion can hide text entering the previous or wrong block. Page key-handler evidence remains distinct from native WebKit keyboard interaction.

- A native test mirror such as `RegistrationFlowSupport.swift` classifying failures
  differently from the production bridge and `registration-flow.ts`. Trace the
  error through the production rejection mapper before comparing cached,
  authorization-required and refusal states; retain native evidence that real
  transport errors reach the fixed code the shared flow consumes. Otherwise a
  passing Swift journey can hide a different production recovery decision.

- A New Message account-race test that replaces the account only with a distinct
  sender, or checks only the returned identifier. Use the same Gmail connection ID
  and address across accounts, finish opening the replacement Drafts before
  releasing the old command, and check that neither its snapshot nor reopened
  storage contains a new Draft. Also cover still-loading replacement storage and
  sign-out/re-entry; otherwise sender membership or a late result fence can hide
  a stale command writing into the replacement account.

- A batched composer-event regression that flushes React between the caret,
  formatting/history command and text change it claims arrive together. Keep
  those handlers in one outer `act` without an intervening rendered-state wait,
  include an active typing-mark override, and assert the real Draft's semantic
  spans. Otherwise fresh selection can hide stale mark state behind a passing
  repeated-character test. Component batching still does not prove native event
  ordering or hardware-keyboard behavior.

- A composer conflict regression that passes a no-op `onRebind` and asserts only
  retained store content. Exercise the owning route/window selection, mounted
  history through Undo/Redo, continued text callbacks before a render, and Discard
  of the bound version. Include storage rebases when they can rename a copy;
  otherwise the test passes while the editor still targets another writer's Draft.
  Include two editors writing identical content before saving, verify every
  callback follows the retained version, and discard through that editor's target
  while preserving the concurrent writer's content. Also exercise a callback
  switching to another pending version, including during notification, so a
  single-editor or content-only assertion cannot hide stale fanout bindings.
  Exercise forced composer unmount during failed/locked-save recovery and while
  confirmed Discard waits behind a held save. Reopen through a fresh store and
  check that recovery keeps both unsaved versions without notifying the closed
  owner, while pending Discard removes its own conflict copy and preserves the
  other writer. A test that always leaves through durable Close cannot detect
  a retained callback or premature identity release.

- A host keyboard regression in `apps/{mobile,macos}/test/` that fires `keyDown` or `keyPress`
  directly without checking the installed native emitter, JavaScript wrapper and
  handled-key consumption contract. A component event bypasses those layers; it
  cannot prove which events reach the callback or which edits native performs.
  Match native text/selection events in the journey, and distinguish that evidence
  from native interaction. Do not assume `keyDownEvents` is a dispatch whitelist;
  otherwise a passing test can justify swallowing an editing key or editing twice.
  On iOS, an empty replacement can synthesize Backspace for either direction;
  exercise deletion with and without that key event using the actual post-edit
  caret payload. A missing key event alone does not prove Forward Delete.
- Native registration journeys creating a new `RegistrationStore` for every
  action without restoring its process-local Product Sign-In session.
  `synchronize` needs that session; otherwise `removeMailbox` only queues a
  tombstone and assertions about remote publication exercise no write. Keep one
  store per simulated process, and explicitly restore or sign in a new instance
  when testing relaunch. Otherwise a hosted lifecycle test fails for its fixture
  or misses the intended descriptor race.
- A packaged mailbox-connection journey such as `InboxTests.appleRegistrationJourney` stopping at the connected-account notice. Open that provider's Inbox and assert a message's body before and after relaunch, alongside another provider when isolation is claimed; distinguish relaunch reading from cache-only evidence that makes the provider unavailable. Otherwise a broken packaged provider reader can pass behind successful authorization. Label synthetic transport separately from live-provider qualification.
- A provider-action journey such as `InboxTests.registrationJourney` or `WindowTests.registrationJourney` treating optimistic controls, the encrypted cache or a done notice as provider confirmation. Check each action before later notices can mask refusal, rule out unfinished saving/sync and retry/authentication/rejected/blocked outcomes, and label synthetic completion proxies separately from provider-side label/readback evidence; otherwise a guarded or unsent write can leave pending intent behind a passing journey.
- An assertion that cannot fail for the regression in question: it asserts the fixture, a mock's return value, a call count or call order, or mirrors the implementation line by line. Ask what plausible defect would turn it red.
- A differential oracle such as `packages/mail-core/scripts/record-webkit-css.ts`
  querying only names returned by the candidate parser. Enumerate the reference
  implementation's outputs independently and compare complete property sets,
  accounting explicitly for reviewed admission differences and derived longhands.
  Verify that dropping an accepted declaration with no covering shorthand, such
  as `display:none`, still fails after rerecording;
  otherwise candidate omissions disappear from both fixture and assertion and
  a broken sanitizer can satisfy its adoption gate.
- The collaboration under test replaced by a mock. Substitute only the external boundary (provider response, native module, clock); stores, Effect services and layers, and Convex functions run for real.
- A store or Convex function tested through an internal helper rather than its public interface (`getSnapshot`/`subscribe`/actions, or the registered function against the test database and identity context).
- An HTTP-driven Convex test in `packages/convex/test`, such as the Gmail ingress
  scenarios in `pushRelay.test.ts`, checking stored or scheduled work without
  asserting the protocol response status. Work can commit before a route returns
  an error, so side-effect assertions alone can pass while the provider retries
  a failed request.
- A changed behavior covered only on its success path when the change adds a failure, cancellation, conflict or recovery path.
- A bug fix with neither a regression test that fails without the fix nor a documented reason automation is unavailable, as permitted by `docs/agents/testing.md`.
- A test whose name states a risk it does not exercise, or a new test with no nameable risk: a trivial accessor, a constant, framework behavior, or one more permutation of a contract already covered at another layer.

#### Privacy and security cases stay covered

- A test for authorization, account or connection isolation, encryption, key safety, data loss or duplicate delivery removed, skipped, weakened or rewritten to assert less, without the pull request naming the retained coverage or why the risk is gone.
- A Convex test that never calls the function as an unauthenticated caller, as a different account, or with a malformed argument when the function guards account data.
- A fixture containing a real email address, token, key or message. Fixtures are synthetic.
- A diagnostic privacy regression, such as deletion recovery in
  `packages/convex/test/productAccount.test.ts`, asserting only that the expected
  allow-listed log call exists. Check that synthetic secrets are absent from all
  captured calls as well; an additional leaking call otherwise leaves the test
  green.

#### Determinism and isolation

- A software-keyboard journey such as `InboxTests.sendJourney` using burst
  `typeText` or an unconfirmed character loop when the field can drop keystrokes
  during keyboard presentation or rerendering. Reuse `InboxTests.type(_:into:)`
  or equivalent per-character value confirmation for that field, including
  recipient input after the keyboard appears. Otherwise the journey can fail
  before admission for malformed input instead of testing delivery, as in #970.
- A journey such as `InboxTests.sendJourney` spending a short-lived state's
  budget on an optional-element timeout or fixed delay before asserting that
  state. Trace the whole path from Send to the Undo Send assertion, including
  composer dismissal and navigation; wait for the actual alternate outcomes and
  continue as soon as either occurs. Otherwise the default 10-second window can
  expire before the test observes it, despite correct product behavior.
- A fake-clock store journey such as
  `packages/mail-core/test/error-reporting-delivery.test.ts` freezing the real
  async runner's continuation scheduler before awaiting `load` or `refresh`. Trace
  the installed runner and timer implementation so the contract's clock and sleeps
  stay controlled while the real collaboration can progress. Otherwise setup can
  stall before retry or withdrawal assertions; a later clock advance or a larger
  timeout does not prove those contracts.

- A shell-runner fixture that replaces an interpreter through `PATH` but inherits
  an explicit interpreter override such as `RUBY`. Set the runner's actual
  override to the test-owned stub too; otherwise CI can invoke a real interpreter
  before reaching the behavior the fixture claims to test.

- A shell contract in `scripts/testflight.test.mjs` supplying a minimal child
  environment without a test-owned `HOME`, or letting host shell initialization
  replace its stub-only `PATH`. Keep the home and startup guards consistent with
  the existing runner fixtures; otherwise hosted Mac initialization can invoke
  real tools instead of the stubs and stop uploads before archiving despite a
  passing local suite.

- A journey that creates an Outbox, synchronizer or another timer/subscription
  owner and disposes it only after its final assertion. Put cleanup in `finally`
  or the test framework's guaranteed teardown, covering setup as well as assertions
  and disposing before other awaited cleanup can reject. Include the current owner
  after relaunch; an assertion or awaited action can fail first, leaving scheduled work
  to mutate later tests after their clocks or external boundaries are replaced.

- `SyntheticGoogleRegistrationProvider.verifyGmail` returning one mutable
  profile address for several saved subjects in a multi-connection journey.
  Configure subject-scoped profiles for that scenario; changing the chosen
  account must not rename another account on refresh. Otherwise isolation
  assertions fail on a fixture-induced cache-owner change instead of exercising
  independent mailbox authorization.
- A synthetic Gmail metadata projection that drops a requested admission header,
  such as Content-Disposition, while a prefetch regression asserts only the final
  cache entry. Match the provider's requested-header projection and check that
  excluded parts never receive a speculative full-body request; otherwise the
  test can pass after downloading the content it claims to exclude.

- A wait on a sleep, a timeout or scheduler ordering where a controlled clock, explicit synchronization or an observable state change is available. A test that needs a timeout to pass is hiding a race.
- An absence check ("nothing happened") that passes because it did not wait long enough.
- State shared between tests: a module-level store, a reused database, a global mock or environment variable not restored, a Keychain service or Simulator not owned by the run.
- Dependence on the network, the wall clock, locale, time zone or test order.
- A required regression test, such as the long-block editor guard in
  `packages/mail-core/test/drafts.test.ts`, deciding pass/fail from elapsed
  wall-clock samples. Relative ratios, fastest samples and sequential comparison
  phases still admit scheduling, JIT and GC noise, so the test can fail or pass
  independently of the regression. Guard the named risk with deterministic
  structure, identity or instrumented work/allocation counts that fail without
  the fix; keep wall-clock performance measurements in benchmarks or explicit
  runtime qualification, labelled separately from functional suite evidence.
- An Effect-returning API tested by calling `Effect.runPromise` by hand rather than `@effect/vitest` (`it.effect`, `layer`) with controlled layers.

#### Evidence is labelled honestly

- A cached-performance journey such as `WindowTests.testWarmCachePerformance`
  leaving its synthetic providers reachable and treating a second open as proof
  of a cache hit. Require provider unavailability or body-request evidence that
  rejects provider reads in each measured window, and verify the evidence source
  observed the priming reads. Trace reader cleanup before claiming repeated opens
  exercise memory rather than disk. Otherwise a provider refetch or a different
  cache tier qualifies without exercising the claimed path.

- A native evidence report such as `WindowTests.reportPerformance` reading an
  append-only probe file while the app or another writer can still append.
  Stop and await the writers or establish a complete snapshot before decoding,
  including records from the final overhead queries. Otherwise a partial JSONL
  record can fail the journey intermittently or omit late evidence.

- A native journey assertion such as `InboxTests.inboxJourney`'s search-value
  check added or changed without evidence from the workflow's selected Xcode
  and runtime at the final head. Inspect the affected iPhone and iPad job results
  after the last journey or host edit; an earlier head or a different local Xcode
  does not establish CI compatibility. Record missing execution as deferred and
  an assertion failure as failed, even when the check is absent from branch
  protection. Otherwise a reviewed journey can break CI after passing local
  checks while automatic merge still permits delivery.

- A Thread anchoring journey recording its baseline only after above-viewport
  bodies have resolved. For `registration-thread`, record a visible text position
  after dragging while an above-body response is held, release it externally,
  observe completion and compare the position on both iPhone and iPad. A final
  header position alone cannot qualify preservation through that transition.

- `scripts/testflight-signing.test.rb` validating imported signing material only
  with Ruby OpenSSL while substituting macOS `security`. That proves preparation
  and orchestration, not Apple's native importer or key-access compatibility.
  Require the credential-free native preflight before production signing setup
  and keep trusted identity selection and archive evidence separate; otherwise a
  passing mock importer can hide a deployment failure in the platform importer.
- A rendered component test, a Mock Mail Session journey, a runner contract test with tool stubs, or a Hermes export described as native E2E, provider, persistence or device evidence. Each proves only what it exercised.
- A native runner that reports success with zero selected tests, reuses a shared Simulator by name, or leaves owned devices, DerivedData or temporary directories behind on failure, cancellation or timeout.
- A mock scenario that accepts anything but a fixed scenario name, or test-only code reachable from a production build.
- A check that could not run recorded as passing rather than deferred.

#### Test lint policy

- Repeated per-line suppressions in `apps/{mobile,macos}/test/` for behavior
  intentionally allowed by the root test override, such as `node/no-sync` for
  `Schema.decodeSync`. Compare the app and root test policies; when the same
  reason applies across tests, use a matching test-only override with its required
  plugin enabled, preserving the Effect boundary rules. Otherwise the hosts drift
  from the intended test policy and each new helper needs another suppression.
  Keep a per-line suppression when its reason is specific to that site.

#### Leave to tooling

Vitest and Jest style rules, formatting, unused variables, type errors, and the enforced `JSON.parse`, `typeof` guard and untagged-error rules. Tests follow the same Effect boundary rules as production code; only the legacy `packages/mail-test-harness` remains exempt until #627. The merged Swift rule covers Swift test mechanics; this file's policy takes precedence where they differ.
