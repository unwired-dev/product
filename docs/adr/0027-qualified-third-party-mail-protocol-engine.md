---
status: accepted
---

# Use a qualified third-party mail protocol engine

Generic IMAP and SMTP connections will use a qualified third-party protocol engine behind the provider-neutral Mailbox Connection adapter rather than a product-owned wire-protocol implementation. The engine owns transport, authentication, protocol framing and parsing, MIME, and connection lifecycle; the product continues to own durable synchronization, local persistence, Stable Provider Message Identity, role mapping, capability policy, retries, privacy controls, and provider-action reconciliation.

## Candidate decision

[SwiftMail](https://github.com/Cocoanetics/SwiftMail) is the preferred candidate because it is actively maintained, supports the required Apple platforms, and provides async IMAP, SMTP, MIME, IDLE, XOAUTH2, UID-based operations, and explicit TLS modes. Release 1.8.0 is not accepted because its public move and copy operations discard the server's `COPYUID` source-to-destination mapping and its SMTP send API does not expose whether a failure happened before or after `DATA`. A future tagged release may qualify only if it exposes verified UID mappings, preserves that SMTP phase distinction, and passes the acceptance gates below. The dependency will be pinned to the exact audited release; the product will not carry a patch, fork, or handwritten IMAP fallback.

[MailCore2](https://github.com/MailCore/mailcore2) and [Postal](https://github.com/snipsco/Postal) are rejected because their maintenance and Apple-toolchain posture do not meet the product's dependency requirements. Direct use of Apple's [swift-nio-imap](https://github.com/apple/swift-nio-imap) is also rejected because it is a low-level, pre-production building block whose use would make the product responsible for the high-level client implementation this decision intends to avoid.

## Acceptance gates

- A vertical spike must pass against both iCloud Mail and Fastmail before the engine becomes a production dependency. It must cover authentication, role discovery without folder-name inference, newest-50 metadata availability, UID/UIDVALIDITY reconciliation, complete-history backfill, selected body-part fetching, provider-backed full-text body search, IDLE recovery and cancellation, SMTP delivery, and verified Sent append. Deterministic and provider-backed search cases must prove a body-only phrase is found in the requested mailbox and that absent, mailbox-excluded, and header-only matches do not become false body matches.
- Secure-transport qualification must reject invalid certificates and hostnames, reject failed or downgraded STARTTLS upgrades, and prove authentication cannot begin before TLS is established. Deterministic TLS-1.0-only servers must also succeed through both implicit TLS and STARTTLS so the compatibility promised by ADR-0026 is exercised.
- Connection-lifecycle qualification must run overlapping sessions for two mailbox connections with distinct credentials. Commands and results must remain connection-scoped, and cancelling one connection's IDLE or in-flight operation must not cancel, disconnect, or deliver callbacks to the other.
- Deterministic incoming and outgoing MIME fixtures must cover supported transfer encodings, multipart alternatives, attachment metadata, and inline content.
- The engine must return verified source-to-destination UID mappings for move and copy. Message-ID matching is not an identity-repair substitute.
- Move, archive, and trash require `MOVE` or targeted `UIDPLUS` removal plus a verified source-to-destination UID mapping such as `COPYUID`, including on servers that advertise `MOVE` without `UIDPLUS`. The adapter must never invoke an unrestricted expunge fallback that could remove unrelated messages.
- UID/UIDVALIDITY reconciliation is the correctness baseline. `CONDSTORE` and `QRESYNC` are optional optimizations whose absence is acceptable only when the deterministic suite and both provider spikes meet the synchronization budget below.
- SwiftMail protocol trace and debug output may contain private data, so production logging must discard all authentication material, mailbox identifiers, and message content. Tests must prove passwords, bearer tokens, authentication exchanges, mailbox identifiers, and message content cannot reach the production log sink.
- The engine must distinguish transient failures proven to occur before SMTP `DATA`, which retain the normal bounded retry policy, from failures during or after `DATA`, which are ambiguous delivery outcomes and are not retried automatically. An API that reports every error after entering its send call as ambiguous does not qualify.
- Qualification must simulate an IMAP Sent append failure after confirmed SMTP acceptance and prove recovery retries only the sent-copy append without invoking SMTP send again.
- Pull requests run deterministic local IMAP/SMTP contract tests. Secrets-backed iCloud and Fastmail compatibility tests run only in an opt-in or scheduled environment, supplemented by a documented manual soak checklist.

## Synchronization budget

The deterministic synchronization fixture contains one mailbox with 10,000 messages whose metadata averages 2 KiB, plus separate no-change and 100-message-change runs after a completed backfill. The server applies a fixed 100 ms round-trip delay and 20 Mbit/s transfer limit. At the 95th percentile over 20 release-build runs on the iPhone 17 reference device, Initial Mailbox Availability must complete within 5 seconds, no-change and 100-message reconciliation within 10 seconds, and complete metadata backfill within 5 minutes. Incremental reconciliation may use at most 20 IMAP command round trips and download 5 MiB; complete backfill pages may contain at most 500 messages and use at most two fetch or search round trips per page plus ten setup and capability round trips. Synchronization may add at most 100 MiB of peak resident memory and must retain ADR-0018's 100 ms main-thread-stall cap. The iCloud Mail and Fastmail spikes use the same message counts and must meet the request, download, page-size, memory, and main-thread limits; their provider/network latency is recorded separately from the deterministic wall-clock thresholds.

SwiftMail will handle IMAP and SMTP setup verification as well as runtime operations if it qualifies, avoiding duplicate protocol stacks. The existing stream implementation remains only for POP3, which SwiftMail does not support. iCloud Mail and Fastmail are certified providers; manually configured servers receive compatibility-based support.
