# Set a local mail performance budget

At the 95th percentile on an iPhone 17 reference device running a release build with a warm encrypted cache, the sidebar and initial thread list must appear within one second from app-launch entry to first rendered content; cached mailbox switching, cached Mail View switching, cached body opening, and opening a warm Draft composer must complete within 200 milliseconds from user selection to rendered interactive content, while opening an empty Draft composer must complete within 300 milliseconds. Direct input and formatting actions must produce visible feedback in the next rendered frame. The fixture contains at least two populated mailbox connections, each with 50 initially available messages and a completed historical metadata backfill; each body-opening measurement uses a cached body. Synchronization, Category filtering, unread counting, formatting, and Draft autosave must not cause any main-thread stall of 100 milliseconds or longer, measured by main-thread responsiveness instrumentation as an absolute cap rather than a percentile. Message-body loading, HTML preparation, inline- and remote-image loading, prefetch, and historical metadata backfill must not disable navigation, Settings, composing, or actions on already available mail. Provider and network latency will be measured and reported separately rather than counted against local rendering. These budgets make the local store the presentation source of truth and require synchronization, decryption, parsing, persistence, and other potentially expensive work to stay off the main thread.

Refreshes never replace cached content with a loading state. A cold thread list uses localized row-shaped skeletons, and a cold message body uses a stable message-shaped placeholder without replacing or blocking the surrounding reader. Synchronization appears only as passive per-connection Mailbox Sync Status, while failures appear inline beside the affected mailbox or message with a retry action. The client has no global loading spinner or blocking loading overlay; progress indicators remain local to the explicit operation they describe.

Read-only mail work is coordinated per Product Account instead of through a global busy state. At most four message-body pipelines run for one Product Account and two for one Mailbox Connection; a provider may reduce only its own connection limit. Each connection has one speculative prefetch or historical lane, and queued interactive body work starts before queued speculation. Authorized remote images use at most six requests for one open message and twelve for the Product Account. Loads with the same Stable Provider Message Identity or remote resource share their provider or network task so consumers do not duplicate cache writes.

Every message in the newest-first Thread reader remains expanded. Bodies intersecting the visible viewport receive load priority over every off-screen body, and scrolling reprioritizes work immediately. After visible work finishes, bodies load automatically in distance-from-viewport order until the Thread is ready; images begin only within the viewport or its one-viewport prefetch margin. Placeholders retain each unloaded message's stable position without blocking already rendered content.

As bodies and images resolve, the reader preserves the topmost visible message and its text offset. Content resolving above the viewport cannot move the content being read. A visible body reveals once beneath its anchored header without a cross-fade, while remote images reserve their sanitized dimensions when available and update the existing document without resetting typography or scroll position.

A message body does not visibly switch from plain text to styled HTML. Cold loading reveals one prepared presentation after its styling is ready, and a warm cache hit restores that same presentation directly. Loading authorized remote images must not recreate the document or reset its typography and scroll state.

The executable Gmail-first fixture is
`MailboxConnectionAdapterTests.testGmailFirstReleaseCachedPresentationMeetsPerformanceBudgets`.
Run it in Release configuration on the iPhone 17 simulator:

```sh
mise exec -- xcodebuild test \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail \
  -configuration Release \
  ENABLE_TESTABILITY=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=TESTING \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  '-only-testing:unwired-mailTests/MailboxConnectionAdapterTests/testGmailFirstReleaseCachedPresentationMeetsPerformanceBudgets()'
```

The test asserts that valid cached bodies make zero provider body requests and that reopening
unchanged authorized remote content makes zero additional remote-host requests. It exercises the
production Product Account scheduler at its four-body/two-per-connection and
twelve-image/six-per-message limits, proves that duplicate message and resource consumers share one
underlying operation, and verifies that visible Thread bodies start before off-screen bodies. Cached
body rendering and viewport scheduling must not stall the main thread for 100 milliseconds or
longer. Provider latency and the one remote-content seed request remain reported separately from
cached presentation samples.

The fixture also exercises the provider-neutral Unified Inbox path with 50 cached messages from
each supported provider family: Gmail, standards-based IMAP and SMTP, Microsoft Graph, reduced
Legacy POP3, and on-premises Exchange Web Services. Building and labeling all 250 local Threads
must remain below the 200-millisecond cached-switch budget at p95 and must not stall the main thread
for 100 milliseconds or longer.
This mixed-provider sample measures local aggregation only; provider and network latency remains
outside the budget.

The unscaled limits above remain the reference-device product budgets. GitHub Actions compiles the
same fixture with the `CI_PERFORMANCE_BUDGET` condition, which applies a 4x scale only to rendered
presentation timings because its hosted simulator is not a reference device, and builds only the
active simulator architecture. Categorization and main-thread-stall limits remain unscaled in CI.
The stall probe enforces monotonic wall-clock time during active main-run-loop cycles so I/O, lock,
and semaphore waits count as user-visible stalls. Current-thread CPU time remains supplemental
diagnostic context for distinguishing application work from hosted-runner descheduling.
The scaled presentation limit is a regression guard for the hosted runner; it does not replace or
relax the unscaled local budget.

CI runs this Release fixture in parallel with the ordinary Debug test pass. The fixture remains a
required affected-project check, but its Release build no longer extends the Debug pass serially.

The same Release fixture also enforces production System Categorization startup for two Gmail
Mailbox Connections with 50 cached Inbox messages each. Each of ten independent samples per
connection reopens a fresh disk-backed SwiftData store, initializes the production categorizer and
encrypted Product Sync assignment services, loads and decrypts a preexisting assignment, syncs and
classifies a mix of Newsletters & Promotions, Invites, Orders, Flights, and body-dependent
messages, and persists the categorized metadata and background context cache. Each connection's
95th-percentile duration must remain below one second, and the combined
synchronization and categorization path must not stall the main thread for 100 milliseconds or
longer. The test prints the maximum per-connection duration and dataset shape; provider and network
latency remain outside this local regression threshold.

This coverage does not move a privacy boundary. Durable Message Metadata remains body-free and
separate from the device-local Bounded Encrypted Body Cache, cached body text is read only when
Minimized Classification Input is insufficient, and both stores remain device-local. This extends,
and does not supersede, `docs/adr/0004-swiftdata-for-local-persistence.md`.
