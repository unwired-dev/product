# Native validation

This guide covers resource ownership for the Expo client and native
React Native macOS host. Commands and toolchain requirements live in
[Expo setup and validation](../expo-client.md#validate); remaining release
checks live in [platform qualification](../qualification/expo-react-native-client.md).
The replacement targets iOS, iPadOS, and macOS 27 or newer.

## Own the resources used by the check

- Before a full native validation matrix, require at least 6 GiB available on
  the data volume. Reclaim only artifacts owned by the current task; otherwise
  report the capacity blocker.
- Create a fresh Simulator for each automated run, record its UDID, boot it, and
  wait for `xcrun simctl bootstatus <udid> -b`. Select it with
  `-destination 'platform=iOS Simulator,id=<udid>'`. Do not use another task's
  device or select a shared Simulator by name.
- Use task-owned DerivedData, result bundles and temporary directories. Arrange
  cleanup on success, failure, cancellation and timeout. Shut down and delete
  only owned devices; preserve the logs and results needed for the handoff.
- Treat a missing `testmanagerd` socket, CoreSimulator service disconnect or an
  unexpected success with zero selected tests as infrastructure failure. Retry
  once on a fresh owned device. An assertion failure is a test failure; normal
  service connection logs do not justify a retry.
- For the Expo Inbox journeys, run `pnpm test:native` from `apps/mobile`
  after the documented build prerequisites. The runner owns its Simulator
  lifecycle and result paths. The [Mac runner](../macos-client.md#verification)
  owns its probe project and results; run it against a task-built app on a
  logged-in macOS desktop.

Follow the [execution-environment policy](testing.md#execution-environment) for
sandbox restrictions and the separate PR babysitter validation boundary.

## Performance qualification

The existing local-mail budgets remain release requirements. Measure a Release
build with a warm encrypted cache on the reference iPhone 17, at least two
connections with 50 initially available messages each, completed backfill and
cached-body samples. Use the current launch-provider scope rather than a
historical Gmail-only fixture.

Also build and label 250 local Threads in the Unified Inbox aggregation fixture,
adapted to the current launch-provider scope. Its p95 must remain below 200 ms,
with no main-thread stall of 100 ms or longer.

| Interaction                                                         | Budget                       |
| ------------------------------------------------------------------- | ---------------------------- |
| App-launch entry to first rendered sidebar and initial message list | p95 at most 1 second         |
| Cached mailbox or Mail View switch, cached body and warm composer   | p95 at most 200 ms           |
| Empty composer                                                      | p95 at most 300 ms           |
| Typing and formatting feedback                                      | Next rendered frame          |
| Main-thread stall                                                   | No stall of 100 ms or longer |

Measure cached switches and body/composer opening from user selection to
rendered interactive content. Measure provider/network latency separately and
keep the app interactive while it waits. Nominate iPad and Mac reference hardware
and establish their baselines;
unmeasured baselines remain required qualification. Hosted-runner speed does not
relax a device budget. Record the device, fixture, build, command and measurement
evidence; these targets do not claim a passing measurement. The reviewer verifies
the decision history in [ADR 0018](../adr/0018-local-mail-performance-budget.md).

## Report what the evidence proves

A production Hermes export verifies the JavaScript bundle. A native build proves
compilation and packaging. Interaction tests prove only the journeys exercised.
None substitutes for real provider, credential, encrypted-storage, accessibility
or physical-device qualification.

Record the target, toolchain, command, result and any unavailable check. Available
native checks should run when relevant; the earlier tooling exception permits
implementation to continue without unavailable version-27 evidence, but does
not waive release qualification or turn deferred checks into passing results.
