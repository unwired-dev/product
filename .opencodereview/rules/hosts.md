Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to the host TypeScript in `apps/mobile` and `apps/macos`.

A host owns views and native adapters. It renders shared stores from `@private-email/mail-core` and passes native modules into them. `apps/mobile` is Expo on iOS and iPadOS (Hermes, Expo Router split view); `apps/macos` is React Native macOS, where AppKit owns windows and each window mounts its own React root over one JavaScript runtime. The two hosts pin different React and React Native versions.

#### The host stays thin

- Application logic in a component, hook or adapter: decoding a native result, deciding a registration or enrollment transition, retrying, merging or filtering mail state. That logic belongs in a `mail-core` store so both hosts and its tests share it.
- A store read any way other than `useSyncExternalStore(store.subscribe, store.getSnapshot)`, or store state copied into `useState` and kept in step by an effect. The copy goes stale between the event and the effect.
- A native module result used in the host before the shared store decodes it. The adapter passes the raw result through; see `src/private-storage.ts`.
- Effect imported into a component or hook. React code is plain TypeScript consuming stores.
- An import of `@private-email/convex`, `@private-email/mail-test-harness`, a `mail-core` path outside its `exports`, or the other host's source.
- The same logic added to both hosts in one change. Two copies drift; move it to `mail-core` unless it depends on a host API.

#### React correctness

- An effect that subscribes, listens (`AppState`, `Linking`, a native emitter) or starts async work without returning cleanup, or whose async result is applied after unmount or after its inputs changed.
- A store action whose returned Promise is awaited in render or left to reject; actions are fired as `void store.action()` and report failure through state.
- An event handled indirectly by an effect that can repeat a store action or apply it to a later selection; trace the user handler and the effect to prove the incorrect transition.
- A list key built from an index where a reorder attaches selection or row state to the wrong message.
- Per-row work in the Inbox `FlatList` that grows with the mailbox: an unstable `keyExtractor`, a row that subscribes to the whole store, or sorting and filtering repeated on every render.
- Selection held anywhere but its owner: route parameters on mobile, the window on Mac. A Mac window opened after another must start with no selection, and a read/unread change must reach every window without changing any selection.

- `RegistrationGate` retaining an Inbox/Account destination choice after the Product
  Account changes or Inbox eligibility is lost. Discard that choice before
  rendering so new Recovery Key, enrollment or authorization steps govern landing.

#### Platform behavior

- A pressable without an accessible role and name, text that does not scale with Dynamic Type, a color taken from a literal rather than the light/dark tokens in `mail-core`'s `theme`, or selection and focus shown by color alone.
- A component library, navigation library or native module added to either host. Mobile uses Router's split view and React Native `StyleSheet`; the Mac host autolinks no additional native modules, and adding one requires updating `apps/macos/scripts/verify-bundle.ts`.
- Mac window identity, menu routing, focus or application lifetime handled in JavaScript. AppKit owns them; closing the last window keeps the app running.
- A route, deep link or window identifier used before validation, or used to select a message in a store that has not confirmed it exists; the unavailable route must render.
- A deployment target, entitlement, Info.plist privacy string or App Transport Security setting lowered or broadened in `app.config.ts`, a config plugin or the Mac project.
- A Metro, Babel or config-plugin change that lets mock-session code (`UNWIRED_MOCK_SCENARIO`, `UNWIRED_REGISTRATION_MOCK`) into a build that did not select a scenario.

#### Bundle and workspace boundary

- A dependency declared with a literal version rather than its `catalog:` entry, taken from the other host's catalog, or added to `dependencies` when only tests use it.
- A change to a host's `scripts/verify-bundle.ts` (`apps/mobile/scripts/verify-bundle.ts`, `apps/macos/scripts/verify-bundle.ts`) that removes or loosens an assertion: the renderer inventory, the stale shared-source comparison, the rejection of the other renderer, Expo, React DOM or backend code in the Mac bundle, or the autolinking list. Version declarations do not prove what the bundle contains; these checks do.

#### Tests in the same change

Apply `docs/agents/testing.md`'s admission and proportionate-verification policy: existing meaningful coverage may suffice; document unavailable automation or protected/native evidence with its required follow-up. The cases below identify missing evidence for a named risk, not a requirement to add a test for every edit.

- A changed journey with no component integration test under the host's `test/` that drives the real `mail-core` store with a substituted native boundary. A rendered component test is not native E2E evidence; a Hermes export proves the bundle, not the behavior.
- A test that mocks the store or asserts a callback was called rather than the rendered outcome.
- Unavailable native evidence reported as passing rather than deferred.

#### Leave to tooling

Hooks-rule violations (including synchronous state setters in effects and nested component definitions), formatting, unused exports, type errors and Effect import style are covered by oxlint, oxfmt, Fallow and the type checker. Inline styles are normal in React Native; flag a style only for a behavior defect.
