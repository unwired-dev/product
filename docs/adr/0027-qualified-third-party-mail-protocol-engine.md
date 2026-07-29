---
status: accepted
---

# Use a qualified third-party mail protocol engine

Generic IMAP and SMTP connections will use a qualified third-party protocol engine behind the provider-neutral Mailbox Connection adapter rather than a product-owned wire-protocol implementation. The engine owns transport, authentication, protocol framing and parsing, MIME, and connection lifecycle; the product continues to own durable synchronization, local persistence, Stable Provider Message Identity, role mapping, capability policy, retries, privacy controls, and provider-action reconciliation.

## Candidate decision

[SwiftMail](https://github.com/Cocoanetics/SwiftMail) is the preferred candidate because it is actively maintained, supports the required Apple platforms, and provides async IMAP, SMTP, MIME, IDLE, XOAUTH2, UID-based operations, and explicit TLS modes. Release 1.8.0 is not accepted because its public move and copy operations discard the server's `COPYUID` source-to-destination mapping and its SMTP send API does not expose whether submission was rejected or has an ambiguous outcome. A future tagged release may qualify only if it exposes verified UID mappings, preserves that SMTP outcome distinction, and passes the acceptance gates below. The dependency will be pinned to the exact audited release; the product will not carry a patch, fork, or handwritten IMAP fallback.

[MailCore2](https://github.com/MailCore/mailcore2) and [Postal](https://github.com/snipsco/Postal) are rejected because their maintenance and Apple-toolchain posture do not meet the product's dependency requirements. Direct use of Apple's [swift-nio-imap](https://github.com/apple/swift-nio-imap) is also rejected because it is a low-level, pre-production building block whose use would make the product responsible for the high-level client implementation this decision intends to avoid.

## Acceptance gates

- A vertical spike must pass against both iCloud Mail and Fastmail before the engine becomes a production dependency. It must cover authentication, role discovery without folder-name inference, creation of a missing role mailbox, newest-50 metadata availability, UID/UIDVALIDITY reconciliation, complete-history backfill, selected body-part fetching, provider-backed full-text body search, read and unread changes, spam-state changes, IDLE recovery and cancellation, SMTP delivery, and verified Sent append. Deterministic and provider-backed search cases must prove a body-only phrase is found in the requested mailbox and that absent, mailbox-excluded, and header-only matches do not become false body matches. Deterministic and provider-backed mutation cases must prove each required provider action and permitted missing-role creation is exposed and reconciles to the expected server state.
- Authentication qualification must include deterministic password rejection plus XOAUTH2 success, challenge, and rejection cases, and a provider-backed XOAUTH2 case for each certified provider account that supports it.
- Secure-transport qualification must reject invalid certificates and hostnames under both implicit TLS and STARTTLS, reject failed or downgraded STARTTLS upgrades, and prove authentication cannot begin before TLS is established. Deterministic TLS-1.0-only and TLS-1.1-only servers must fail through both implicit TLS and STARTTLS during initial setup and IDLE recovery, while TLS-1.2-or-newer servers must succeed, so the minimum restored by ADR-0028 is exercised without requiring TLS 1.3. IMAP and SMTP transport modes must be independently configurable and include an implicit-TLS IMAP plus STARTTLS SMTP case.
- Connection-lifecycle qualification must run overlapping sessions for two mailbox connections with distinct credentials and distinguishable mailbox and SMTP data. Commands, results, SMTP submissions, and IDLE callbacks must remain connection-scoped, cancelling one connection's IDLE or in-flight operation must not cancel, disconnect, or deliver callbacks to the other, and any service whose authentication fails must close its established transport along with any service authenticated earlier in setup. Closing a connected session must tear down both authenticated services, and every session operation must reject work after close.
- Deterministic incoming and outgoing MIME fixtures must cover supported transfer encodings, multipart alternatives, attachment metadata, and inline content.
- The engine must return verified source-to-destination UID mappings for move and copy. Deterministic fixtures must capture the source mailbox, source UIDs and UIDVALIDITY, and destination mailbox actually sent for both commands. Malformed, partial, repeated, or nonpositive server UIDs and destination UIDVALIDITY values must be rejected through the candidate operations rather than only by a shared validator. Message-ID matching is not an identity-repair substitute.
- Move, archive, and trash require `MOVE` or targeted `UIDPLUS` removal plus a verified source-to-destination UID mapping such as `COPYUID`, including on servers that advertise `MOVE` without `UIDPLUS`. The adapter must never invoke an unrestricted expunge fallback that could remove unrelated messages.
- UID/UIDVALIDITY reconciliation is the correctness baseline. UIDVALIDITY must remain mailbox-scoped, stale identities must be rejected before a copy or move command reaches the server, and selected body-part results must be bound to the requested mailbox, UIDVALIDITY, and UID. `CONDSTORE` and `QRESYNC` are optional optimizations whose absence is acceptable only when the deterministic suite and both provider spikes meet the synchronization budget below.
- SwiftMail protocol trace and debug output may contain private data, so production logging must discard all authentication material, mailbox identifiers, and message content. Tests must exercise body fetch, SMTP submission, and Sent append, capture every candidate-owned trace and debug path as raw bytes as well as the supplied product logger, and prove passwords, bearer tokens, authentication exchanges, mailbox identifiers, and message content cannot reach any captured output.
- The engine must distinguish retryable and permanent IMAP rejections from transport failures whose command outcome is unknown, preserving the tagged response code needed for classification. Deterministic cases must prove permanent rejections are not retried, retryable failures retain bounded retry, and an uncertain mutation is reconciled before any replay.
- The engine must distinguish transient and permanent sender, recipient, and `DATA` rejections before message content, explicit final `4xx` and `5xx` responses after message content, and a missing or otherwise indeterminate final response after message content. Only the indeterminate post-content case is an ambiguous delivery outcome that is not retried automatically; an accepted response remains accepted when it has no parseable server message ID. The deterministic fixture must exercise real task cancellation before content transmission and must also capture and verify every recipient plus the exact raw message accepted by SMTP. An API that reports every error after entering its send call as ambiguous, or cannot distinguish an explicit rejection from an unknown outcome, does not qualify.
- Qualification must simulate an IMAP Sent append failure after confirmed SMTP acceptance and prove recovery retries only the sent-copy append without invoking SMTP send again, uses the discovered special-use Sent mailbox rather than a canonical name, appends the exact bytes accepted by SMTP, and returns the complete Sent mailbox identity.
- Pull requests run deterministic local IMAP/SMTP contract tests. Secrets-backed iCloud and Fastmail compatibility tests run only in an opt-in or scheduled environment, supplemented by a documented manual soak checklist.

## Synchronization budget

The deterministic synchronization fixture contains one mailbox with 10,000 messages whose metadata averages 2 KiB, plus separate no-change and 100-message-change runs after a completed backfill. The server applies a fixed 100 ms round-trip delay and 20 Mbit/s transfer limit. At the 95th percentile over 20 release-build runs on the iPhone 17 reference device, Initial Mailbox Availability must complete within 5 seconds, no-change and 100-message reconciliation within 10 seconds, and complete metadata backfill within 5 minutes. Incremental reconciliation may use at most 20 IMAP command round trips and download 5 MiB; complete backfill pages may contain at most 500 messages and use at most two fetch or search round trips per page plus ten setup and capability round trips. Synchronization may add at most 100 MiB of peak resident memory and must retain ADR-0018's 100 ms main-thread-stall cap. The iCloud Mail and Fastmail spikes use the same message counts and must meet the request, download, page-size, memory, and main-thread limits; their provider/network latency is recorded separately from the deterministic wall-clock thresholds.

SwiftMail will handle IMAP and SMTP setup verification as well as runtime operations if it qualifies, avoiding duplicate protocol stacks. The existing stream implementation remains only for POP3, which SwiftMail does not support. iCloud Mail and Fastmail are certified providers; manually configured servers receive compatibility-based support.

## Executable qualification boundary

`MailEngine.swift` defines the provider-neutral, transient engine façade before
any candidate dependency is adopted. It exposes negotiated transport and
capabilities, mailbox and stable UID/UIDVALIDITY results, bounded metadata and
selected body-part reads, IDLE, verified copy/move mappings, phase-aware SMTP
outcomes, and Sent append. It deliberately exposes no persistence, retry,
Mailbox Role mapping, or reconciliation API, keeping those decisions in
product-owned services.

`MailEngineQualificationTests.swift` supplies the reusable deterministic
contract. A candidate-specific test file in the `unwired-mailTests` target
provides a `MailEngineQualificationCandidateFactory` for the same fixtures,
including fixture-specific bound IMAP and SMTP endpoints, and must pass the
contract unchanged. The reference scripted candidate proves the
harness covers per-service TLS and authentication ordering, certificate and
server-identity failures, connection isolation and cancellation, UID mapping
and UIDVALIDITY resets, order-independent mailbox and body-part results, paging and body selection, bounded IDLE recovery waits with the TLS floor reapplied,
actual metadata mailbox/cursor/limit requests, pre- and post-content SMTP task cancellation, sender/recipient/`DATA` rejection, accepted responses without message IDs, exact multi-recipient SMTP and Sent-append payloads,
Sent-append-only recovery, partial-setup cleanup, and complete candidate trace capture.
Provider-backed, MIME, search, mutation, and performance qualification remain
the later gates already defined above.
