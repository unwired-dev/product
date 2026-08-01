# Set a local mail performance budget

At the 95th percentile on an iPhone 17 reference device running a release build with a warm encrypted cache, the sidebar and initial thread list must appear within one second from app-launch entry to first rendered content; cached mailbox switching, cached Mail View switching, cached body opening, and opening a warm Draft composer must complete within 200 milliseconds from user selection to rendered interactive content, while opening an empty Draft composer must complete within 300 milliseconds. Direct input and formatting actions must produce visible feedback in the next rendered frame. The fixture contains at least two populated mailbox connections, each with 50 initially available messages and a completed historical metadata backfill; each body-opening measurement uses a cached body. Synchronization, Category filtering, unread counting, formatting, and Draft autosave must not cause any main-thread stall longer than 100 milliseconds, measured by main-thread responsiveness instrumentation as an absolute cap rather than a percentile. Provider and network latency will be measured and reported separately rather than counted against local rendering. These budgets make the local store the presentation source of truth and require synchronization, decryption, parsing, persistence, and other potentially expensive work to stay off the main thread.

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
  -only-testing:unwired-mailTests/MailboxConnectionAdapterTests/testGmailFirstReleaseCachedPresentationMeetsPerformanceBudgets
```

The test prints provider latency separately from cached presentation samples.
