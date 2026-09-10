# Expo and React Native client rewrite research

Research date: 2026-09-09.

Status: product-scope interview and shared-understanding confirmation complete;
implementation authorized. Dependency and shared-source bundling probes passed.
The maintainer authorized proceeding without native version-27 validation until
suitable tooling is available to the project. This note records the agreed direction,
verified constraints, and remaining technical qualification. Accepted decisions are
recorded in [ADR 0059](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md),
[ADR 0060](../adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md),
[ADR 0061](../adr/0061-separate-product-identity-from-registration-mailbox-authorization.md),
[ADR 0062](../adr/0062-keep-queued-delivery-on-its-originating-device.md),
[ADR 0063](../adr/0063-notify-for-new-inbox-mail-without-categorization.md), and
[ADR 0064](../adr/0064-isolate-mobile-and-macos-native-dependencies.md).
The replacement is not implemented. The approved first-release breakdown is
published as 37 GitHub Issues, beginning with
[the mobile mock Inbox (#592)](https://github.com/unwired-dev/product/issues/592)
and ending with
[separate mobile and Mac TestFlight builds (#628)](https://github.com/unwired-dev/product/issues/628).
The approved 39 follow-ups and two public-release steps are also published.
See [the complete ticket coverage audit](../qualification/expo-rewrite-ticket-coverage.md)
for all 78 issues, scope corrections, and the verified dependency graph. Native version-27
qualification is tracked separately in
[#623](https://github.com/unwired-dev/product/issues/623) and does not block feature
implementation. Follow [the issue-tracker policy](../agents/issue-tracker.md) for
ongoing implementation tracking.

## Requested direction

- Replace the entire client with Expo and React Native for iPhone, iPad, and Mac
  to improve development speed and user experience, with Android and Windows later.
- Replace existing client mail engines; consider new native libraries exposed to
  JavaScript where useful.
- Replace Apple-first Product Account sign-in with Google and Apple, with Microsoft
  later. Registration also initiates Gmail authorization.
- Target an Apple platform deployment floor of version 27 to use the latest
  Apple AI capabilities. Launch assistance covers summaries, rewriting, reply
  assistance, and translation, with useful ordinary mail when AI is unavailable.
- Provide a mock mode for deterministic end-to-end testing.
- Replace obsolete tests with tests that protect meaningful behavior, retaining
  or replacing coverage for data loss, duplicate sends, identity isolation,
  encryption, and critical journeys.
- Update all affected documentation with the implementation.

## Findings that shape the design

### Desktop support needs a separate feasibility check

The existing client uses SwiftUI and Mac Catalyst, with a version 26 deployment
floor. React Native macOS supplies an AppKit-based desktop route, but its
[Expo integration documentation](https://microsoft.github.io/react-native-macos/docs/guides/installing-expo-modules)
explicitly marks macOS support for Expo modules as experimental.
[Expo's additional-platform guidance](https://docs.expo.dev/modules/additional-platform-support/)
also requires modules to account for differences between UIKit and AppKit.
An iOS dependency working in Expo does not establish that it works on desktop.
The accepted host structure is Expo on iPhone/iPad and a separate React Native
macOS host sharing TypeScript application code, with new native modules where
required. The first implementation milestone must qualify that structure.

[Expo supports custom native code](https://docs.expo.dev/workflow/customizing/),
including Swift modules and wrappers around existing libraries. Such modules
require a development build; Expo Go cannot load arbitrary native code.
This provides a binding mechanism, not a qualified library for every provider.

Apple also documents [Mac Catalyst](https://developer.apple.com/help/account/capabilities/create-a-mac-version-of-an-ipad-app).
Whether the selected Expo and React Native dependencies work through that route
requires a build and behavior check. The intended Mac experience must determine
which route to qualify. The second-round decision selected React Native macOS;
Catalyst is a researched alternative, not the selected replacement host.

### Native dependencies require independent installations

The exact Expo 57.0.21 package specifies React Native 0.86.3 and React 19.2.3,
while React Native macOS 0.81.9 requires React Native 0.81.6 and React `^19.1.4`.
The macOS
[setup guide](https://microsoft.github.io/react-native-macos/docs/getting-started)
requires matching React Native minor versions. Expo also documents limitations on
[duplicate native packages in monorepos](https://docs.expo.dev/guides/monorepos/#duplicate-native-packages-within-monorepos).
Use separate package roots, lockfiles, native autolinking scopes, and Metro
resolvers, sharing framework-independent TypeScript. Both exact host installations
passed strict dependency checking and bundled the same TypeScript fixture;
Expo's dependency check also passed. Source-map inspection found only each host's
intended React and native graph. See
[the platform qualification record](../qualification/expo-react-native-client.md)
for the exact evidence and limitations. Shared React UI and native runtime
compatibility remain unproven.

Current [Expo SQLite documentation](https://docs.expo.dev/versions/latest/sdk/sqlite/#sqlcipher)
lists macOS and opt-in SQLCipher support, but that support must be verified for the
eventually selected package line. The current
[SecureStore platform list](https://docs.expo.dev/versions/latest/sdk/securestore/)
does not include macOS. Desktop credential storage therefore needs a qualified
Keychain adapter with explicitly device-local behavior.

Apple documents native macOS application testing through
[XCUIApplication](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/init%28bundleidentifier%3A%29).
This supplies a desktop E2E candidate independent of the mobile runner. It still
needs a real test against the replacement's accessibility tree and the exact app
bundle produced by its build.

The first implementation milestone must establish one compatible dependency
arrangement; build both actual hosts with packaged JavaScript and a native module;
exercise encrypted persistence and device-local credential lifecycle; and run a
deterministic visible mail journey with keyboard interaction and persistence after
relaunch. Desktop menu, multi-window, and background checks remain part of that
milestone. Dependency installation and JavaScript bundling are now checked;
native build and runtime evidence is deferred with the maintainer's authorization.
The missing version-27 environment does not block implementation and does not
justify lowering the deployment floors.

### Platform version and AI availability are separate requirements

Apple documents [iOS 27](https://developer.apple.com/ios/whats-new/),
[macOS 27](https://developer.apple.com/macos/whats-new/), and
[Foundation Models changes for version 27](https://developer.apple.com/documentation/Updates/FoundationModels).
The pages inspected still describe beta tooling; general-release readiness was
not established by this research.

[SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
reports runtime unavailability, including an ineligible device, disabled Apple
Intelligence, or a model that is not ready. Apple's
[eligibility requirements](https://support.apple.com/en-us/121115) also include
hardware and language or region constraints. A version 27 deployment floor does
not replace availability handling.

The existing [Mail Assistance decision](../adr/0052-keep-mail-assistance-on-device-and-input-bound.md)
requires explicit, input-bounded on-device inference and useful mail functionality
when assistance is unavailable. Apple's iOS 27 overview also describes Private
Cloud Compute access. Adopting a newer API must not silently change the existing
on-device-only product promise.

### Product identity is separate from mailbox permission

[CONTEXT.md](../../CONTEXT.md) defines a Product Account independently of its
Mailbox Connections and device-local Mailbox Authorization. It now defines
Product Sign-In independently of Mailbox Authorization. The existing implementation
still uses Apple-first Product Account authentication.

Adding Google sign-in to the Product Account must specify whether and how it
links to an existing identity. Signing in with Google and granting access to a
Gmail mailbox are separate permissions, even if the interface offers both in one
onboarding journey. Account recovery, device trust, deletion, and reauthentication
also need review because current workflows depend on Apple authentication.

### Provider-native does not mean one universal SDK

The accepted [provider-adapter decision](../adr/0011-provider-native-mail-adapters.md)
uses Gmail REST, Microsoft Graph, IMAP/SMTP, on-premises EWS, and a reduced POP3
capability. These adapters intentionally expose different capabilities.

The repository already contains [provider-library research](../archive/official-mail-provider-sdks.md).
That research is historical input, not proof of React Native compatibility. The
later [Gmail SDK decision](../adr/0056-keep-google-gmail-rest-client-internal-only.md)
keeps Google's generated REST client internal-only after qualification. A rewrite
must explicitly reassess that trade-off before adopting it in production.

### Mock journeys and provider correctness need distinct evidence

The existing [Mail Test Harness](../mail-test-environment.md) runs synthetic mail
through the real client, persistence, and local IMAP/SMTP servers. Its
[test bootstrap](../adr/0033-bootstrap-mail-tests-without-external-product-authentication.md)
bypasses external Product Account authentication in test-only builds.
[ADR 0037](../adr/0037-keep-mail-test-control-outside-the-app.md) keeps test control
outside the application. The accepted
[mock-mode decision](../adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md)
now permits simulated provider behavior in the replacement's isolated test path.

[Expo documents Maestro-driven E2E workflows](https://docs.expo.dev/eas/workflows/examples/e2e-tests/)
for mobile builds. This does not establish desktop macOS automation support.
The desktop route needs its own demonstrated E2E runner.

The existing [testing policy](../agents/testing.md) already admits tests by the
risk they protect and permits retirement of superseded or duplicated coverage.
Mocked UI journeys cannot by themselves establish real OAuth, provider protocol,
native binding, persistence, or live-model correctness.

## First-round decisions

- Replace all client implementation; do not preserve the existing Swift mail engines.
- Require Mac menus, keyboard shortcuts, multiple windows, and background operation.
- Permit a fresh start because the prototype has no users. Existing-user migration
  is not a release requirement. The second round selected a focused first release.
- Support only Gmail initially, with IMAP/SMTP and Microsoft 365 later.
- Connect a mailbox as part of registration after obtaining its required grant.
  The second round selected Google and Apple; the third selected resumable
  mailbox setup after an interrupted or declined grant.
- Keep mail usable without AI and preserve on-device-only assistance. The second
  round selected the launch assistance features below.
- Provide both deterministic synthetic journeys and real integration evidence.
- Retire obsolete implementation tests while retaining or replacing meaningful
  risk coverage.

## Second-round decisions

- Offer Google and Apple Product Sign-In. Google registration requests Gmail
  access; Apple registration continues into Google authorization. Microsoft follows later.
- Retain Convex while rebuilding authentication and changing affected contracts.
- Use Expo mobile and a separate React Native macOS host, sharing TypeScript code
  and adding new native modules for system integration.
- Qualify desktop menus, shortcuts, multiple windows, background operation, and
  automated testing before building the remaining features on that host structure.
- Launch with multiple Gmail accounts, a unified inbox, reading/search,
  attachments, drafts/replies/sending, offline cache, reliable Outbox, notifications,
  and on-device summaries, rewriting, reply assistance, and translation.
- Defer advanced profiles, automation, scheduled sending, and contact/calendar extraction.
- Preserve End-to-End Encrypted Product Sync and device-local mailbox credentials.
  Each new device must obtain its Gmail authorization and independently recover
  or receive the Product Sync keys.

## Third-round decisions

- Apple and Google can become alternate sign-ins through explicit linking that
  verifies both identities. Matching emails never merge Product Accounts, and
  adding a Gmail mailbox never silently adds a Product Account sign-in.
- Retain the Product Account after declined, cancelled, or unavailable Gmail
  authorization and provide resumable mailbox setup, including account reselection.
- Keep normal new-device enrollment through trusted-device approval and a
  Recovery Key fallback. The user's clarification explicitly limits database
  clearing to a one-time reset of today's unused development data. It does not
  replace production recovery or permit automatic resets on missing local keys.
- Keep local message lists usable immediately, with recent bodies in a 500 MB
  encrypted device-wide cache and attachments downloaded on demand. Sender/subject
  search is offline; Gmail full-text search is online. Show when uncached content
  requires a download.
- Synchronize rich-text Drafts and assets end-to-end encrypted, preserving
  conflicting edits. The originating device owns queued delivery, with a default
  10-second Undo Send window and no automatic resubmission while delivery is unknown.
- Notify for new Inbox mail after permission, with per-connection switches and
  generic content by default. Sender/subject previews require opt-in. Historical
  synchronization does not notify, and categorization is not a prerequisite.
- Closing the last Mac window leaves the app running and synchronizing. Explicit
  Quit stops synchronization and queued delivery until reopening. Defer a separate
  helper; iPhone and iPad background execution remains best effort.

## Registration and Gmail authorization

Google permits an authorization request to include
[identity and API scopes](https://developers.google.com/identity/openid-connect/openid-connect).
However, [granular permissions](https://developers.google.com/identity/protocols/oauth2/resources/granular-permissions)
allow a person to grant identity access while denying Gmail scopes. Registration
must check the actual grant before marking a Mailbox Connection authorized.
Also, [a Google Account can use a non-Gmail address](https://support.google.com/accounts/answer/27441?hl=en-GB);
successful Google sign-in does not establish that Gmail is enabled.

Sign in with Apple can supply a
[private relay address](https://developer.apple.com/documentation/signinwithapple/communicating-using-the-private-email-relay-service),
not a Gmail permission grant. Apple's separate
[iCloud account-data access](https://support.apple.com/en-sg/121539) does not change
the Gmail-only first-release scope. The accepted onboarding design continues
Apple registration into Google mailbox authorization. The requirement for a
separate grant follows from the providers' authorization contracts; it does not
claim that either provider authorizes the other provider's mail.

Google's official [JavaScript client](https://github.com/googleapis/google-api-nodejs-client)
targets Node.js. The [Gmail REST API](https://developers.google.com/workspace/gmail/api/reference/rest)
is available to other clients, so a fresh TypeScript REST adapter is a candidate
for the shared client. Neither fact qualifies a particular React Native library.

## Distribution facts

Apple documents [TestFlight](https://testflight.apple.com/) for iOS, iPadOS, and
macOS. Native Mac applications can use the Mac App Store or
[Developer ID distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).
Direct Mac distribution adds its own signing, notarization, packaging, and update
delivery decisions. The accepted separate Mac host also needs a Mac build/archive
pipeline; [Expo's iOS submission flow](https://docs.expo.dev/submit/ios/) handles
the iOS package and does not establish macOS submission support.

## Final-round decisions

- Use TestFlight for beta testing and the App Store/Mac App Store for release.
  Defer direct Mac downloads and their separate update delivery.
- Treat Convex as a required service. Coordinate competing submissions of one
  synchronized Draft with a content-free atomic claim before Gmail handoff.
  Keep ordinary pending/error behavior for an unsuccessful operation, without a
  separate outage mode, fallback coordinator, or uncoordinated sending path.

No product-choice questions remain on the interview frontier. The maintainer
confirmed shared understanding and authorized implementation. Package versions
and routine implementation details are engineering work to resolve against the
evidence below, not additional preferences to ask the user to select.

## Implementation gates

| Gate                         | Work                                                                                                                                                                                 | Required evidence                                                                                                                                                                                                                                                                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Platform qualification       | Select a compatible Expo/React Native/macOS dependency arrangement and build the shared TypeScript foundation with new native modules.                                               | Both actual hosts launch with packaged JavaScript. iPhone/iPad adaptive presentation and Mac menus, shortcuts, independent windows, close/quit behavior, persistence after relaunch, and deterministic visible UI automation work. Verify device-local Keychain storage and encrypted database behavior against the selected package line. |
| Identity and private data    | Build Google/Apple registration, Gmail consent, explicit linking, resumable setup, device enrollment/recovery, and encrypted Product Sync.                                           | Tests prove identity and mailbox-grant separation, isolation between Product Accounts, absence of automatic email-based linking or key replacement, and key transfer/recovery without backend plaintext. Mock identities have no authority over real accounts.                                                                             |
| Gmail Core Mail Loop         | Implement multiple Gmail connections, incremental synchronization, local lists and search, bounded body cache, reader, attachments, rich-text Draft sync, and owned Outbox delivery. | Deterministic visible journeys cover receive/read/organize/compose/reply/send and relaunch. Gmail transport contracts exercise actual adapters. Concurrent same-Draft sends acquire at most one owner; unknown provider delivery never triggers blind resubmission. Cache, account, and device isolation survive restart and teardown.     |
| Assistance and notifications | Add the selected on-device assistance capabilities and private new-Inbox notifications.                                                                                              | Deterministic tests cover success, unavailable models, cancellation, stale results, and explicit acceptance. Historical backfill does not notify. Real Apple AI and Gmail authorization/compatibility receive separate physical-device or protected-provider qualification.                                                                |
| Cutover and release          | Reset only the identified unused development data, retire the old client and obsolete tests, update every affected document and CI gate, and prepare separate mobile/Mac releases.   | Retained risks have coverage or an explicit reason for retirement. All required lint, format, types, native builds, focused tests, and platform E2E checks pass. Documentation links and commands refer to the replacement. TestFlight artifacts are built from the validated implementation.                                              |

A demonstrated platform-qualification failure requires revisiting the technical
approach with concrete evidence. The maintainer explicitly authorized proceeding
while native version-27 validation is unavailable; record those checks as deferred
until suitable tooling is available and complete them before release. A successful
mobile build is not evidence for the Mac host. Dependency and JavaScript bundle
checks passed, but no native build or runtime qualification has run. No database
reset has run.

## Verification targets

Use the applicable product targets in
[ADR 0018](../adr/0018-local-mail-performance-budget.md) as starting requirements,
measured in Release with a warm encrypted cache on the iPhone 17 reference device:

- App entry to sidebar and initial Thread list: p95 at most one second.
- Cached mailbox switch, cached body open, and warm Draft composer: p95 at most 200 ms.
- Empty Draft composer: p95 at most 300 ms; typing and formatting update on the next rendered frame.
- No main-thread stall of 100 ms or longer.

Use multiple Gmail connections with completed metadata backfill and cached bodies.
Adapt the existing 250-Thread aggregation fixture to Gmail connections rather than
retaining five provider families that are outside launch scope. Measure provider
and network time separately, and keep already-available mail interactive during
loading. The deferred categorization benchmark is not a first-release gate.

Nominate and record iPad and Mac reference hardware during platform qualification;
the current documentation has no measured performance baseline for them. Do not
report the iPhone targets as already verified on another platform or apply a
hosted-runner timing multiplier as a product target.

Retain [the testing policy](../agents/testing.md)'s feedback budgets: focused warm
checks within two minutes, required Apple PR validation at a 20-minute p95 after
runner allocation, and nightly validation within 60 minutes. Measure setup/build
separately from tests and cancel superseded runs. Keep only tests protecting named
product, privacy, delivery, persistence, concurrency, or platform risks.

## Documentation impact

| Documentation                                                                                                                                                              | Required review once the corresponding design is settled                                                                 |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `CONTEXT.md`                                                                                                                                                               | Resolve sign-in, provider, and test-mode terminology; keep new implementation decisions out of the glossary.             |
| `docs/adr/`                                                                                                                                                                | Record accepted architectural trade-offs and mark affected earlier decisions superseded, preserving their history.       |
| `README.md`, `AGENTS.md`, `apps/unwired-mail/AGENTS.md`                                                                                                                    | Replace setup, workspace, build, simulator, deployment, and validation instructions when the replacement actually works. |
| `.patterns/`, `docs/archive/bootstrap-review.md`                                                                                                                           | Reassess Swift-specific patterns, shared contracts, encrypted records, and the documented application structure.         |
| `docs/agents/testing.md`, `docs/mail-test-environment.md`                                                                                                                  | Define mock boundaries, meaningful retained coverage, test retirement, per-platform E2E commands, and CI cadence.        |
| `docs/qualification/`, `docs/research/`, `docs/gmail-provider-test-tenant.md`                                                                                              | Update provider and AI qualification evidence; label historical SDK research where new decisions supersede it.           |
| `docs/storage-and-product-sync-export.md`, `docs/archive/scheduled-send.md`, `docs/archive/settings-redesign.md`, `docs/archive/client-stability-and-composer-redesign.md` | Reconcile storage, encryption, background delivery, settings, composer, and migration behavior against the agreed scope. |
| `.github/workflows/`, `.changeset/`                                                                                                                                        | Align executable checks and release notes with the implemented platform and behavior changes.                            |

Documentation verification must include a repository-wide search for stale
commands, platform floors, Apple-only authentication assumptions, retired test
targets, and links to removed files. Historical ADRs retain context with explicit
supersession rather than being rewritten as if the earlier decisions never existed.
