# ADR 0056: Keep the Google Gmail REST client internal-only

## Status

Accepted

## Context

Issue #434 qualifies Google's official `GoogleAPIClientForREST_Gmail` package against the
product-owned `GmailMessageSearching` boundary. The qualification must not move Google transport
types into product models or change the production Gmail path.

The evaluated package is `google-api-objectivec-client-for-rest` 5.4.0 at revision
`07cd7c8ca9119dc08afd4bad52280bd3b763196c`, pinned exactly through Swift Package Manager. It is
Apache-2.0 licensed. Resolution also adds `gtm-session-fetcher` 5.3.1 at revision
`724a52eea6329b7e12d3ad8300d76ca9f3895fcc`.

The package privacy manifest declares no tracking, tracking domains, collected data types, or
required-reason API use. The candidate additionally disables GTM HTTP console and file logging
when its client is initialized. Authentication remains connection-scoped: the product refreshes
and verifies the device-local token, and the adapter places that token only on the corresponding
generated query.

## Decision

Keep the generated client available only in Debug, Testing, or an explicitly compiled
`UNWIRED_INTERNAL_GOOGLE_GMAIL_REST` build. Release builds continue to construct
`GmailMessageMetadataService`, so the production request path is unchanged.

Do not approve a production migration for provider search alone. The generated client is
behaviorally suitable, but its cost is disproportionate to this narrow slice. A future proposal
may reconsider it only as a separately approved, broader Gmail transport migration with its own
binary budget and staged rollout.

The adapter owns all generated types. It returns the existing product-owned
`GmailMessageMetadata`, reuses the direct path's response mapping, limits search to 100 messages,
limits list pages to 256 KiB and message responses to 1 MiB, manually follows page tokens, and
disables both SDK retries and automatic pagination. Gmail history synchronization stays on the
existing direct transport and therefore keeps its current cursor semantics.

Cancellation uses a lock-protected one-shot continuation bridge. It handles cancellation before
or after the SDK ticket is installed, cancels only that ticket, and cannot resume the continuation
twice. SDK errors do not cross the boundary; provider failures normalize to the existing
`gmailRequestFailed` error. Cancellation remains semantically cancellative: the direct URLSession
path may surface `NSURLErrorCancelled`, while the generated client surfaces `CancellationError`.

## Qualification evidence

The deterministic matrix runs both transports through success, two-page pagination,
authentication failure, rate limiting, malformed responses, and cancellation. Additional tests
verify in-flight ticket cancellation, per-connection authorization isolation, and the SDK retry,
pagination, logging, version, and revision policy. The focused suite contains 13 cases and performs
no network requests.

Release measurements used the same iPhone 17 / iOS 26.5 Simulator, package cache, active
architecture, and otherwise clean DerivedData directories. Baseline was commit
`0ecbb51e391786b438415dd4875ff18dba2888a4`.

| Measurement | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Clean Release build wall time | 205.70 s | 205.18 s | -0.52 s (-0.3%) |
| App executable | 93,966,384 bytes | 95,367,968 bytes | +1,401,584 bytes (+1.5%) |
| App bundle | 93,588 KiB | 95,028 KiB | +1,440 KiB (+1.5%) |
| Compiled dependency objects | 0 | 18 Google + 9 GTM | +27 |

Headless `xcodebuild` did not create an `Index.noindex/DataStore` for either Release build, so an
Xcode indexing-time or index-store-size delta was not directly measurable in this environment.
The added generated surface is bounded to the Gmail product plus its core transport dependency;
the single-sample clean-build result above shows no measurable regression but is too noisy to claim
an improvement. An interactive Xcode indexing measurement remains optional evidence, not a merge
prerequisite for this rejected migration.

No direct transport code is removed by the qualification. A search-only migration could remove
the direct `searchProvider` orchestration and `listProviderSearchMessages` request builder, roughly
60 lines, but message retrieval, token refresh, response models, history, synchronization, and
provider actions would remain. That limited deletion does not justify the measured binary cost or
the Objective-C-to-Swift concurrency bridge.

## Consequences

- Internal builds exercise an official generated Gmail query path behind the real product
  boundary without exposing generated types to callers.
- Production behavior and Gmail history semantics remain unchanged.
- Package resolution and Release binaries include the exact-pinned dependency so the
  qualification stays reproducible; this measured cost is the principal reason not to switch
  production search.
- Any future production adoption requires a new decision, issue, migration plan, and measurement
  covering the broader Gmail transport surface.
