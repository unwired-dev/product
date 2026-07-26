---
status: accepted
---

# Use a qualified third-party mail protocol engine

Generic IMAP and SMTP connections will use a qualified third-party protocol engine behind the provider-neutral Mailbox Connection adapter rather than a product-owned wire-protocol implementation. The engine owns transport, authentication, protocol framing and parsing, MIME, and connection lifecycle; the product continues to own durable synchronization, local persistence, Stable Provider Message Identity, role mapping, capability policy, retries, privacy controls, and provider-action reconciliation.

## Candidate decision

[SwiftMail](https://github.com/Cocoanetics/SwiftMail) is the preferred candidate because it is actively maintained, supports the required Apple platforms, and provides async IMAP, SMTP, MIME, IDLE, XOAUTH2, UID-based operations, and explicit TLS modes. Release 1.8.0 is not accepted because its public move and copy operations discard the server's `COPYUID` source-to-destination mapping. A future tagged release may qualify only if it exposes verified UID mappings and passes the acceptance gates below. The dependency will be pinned to the exact audited release; the product will not carry a patch, fork, or handwritten IMAP fallback.

[MailCore2](https://github.com/MailCore/mailcore2) and [Postal](https://github.com/snipsco/Postal) are rejected because their maintenance and Apple-toolchain posture do not meet the product's dependency requirements. Direct use of Apple's [swift-nio-imap](https://github.com/apple/swift-nio-imap) is also rejected because it is a low-level, pre-production building block whose use would make the product responsible for the high-level client implementation this decision intends to avoid.

## Acceptance gates

- A vertical spike must pass against both iCloud Mail and Fastmail before the engine becomes a production dependency. It must cover authentication, role discovery without folder-name inference, newest-50 metadata availability, UID/UIDVALIDITY reconciliation, complete-history backfill, selected body-part fetching, IDLE recovery and cancellation, SMTP delivery, and verified Sent append.
- The engine must return verified source-to-destination UID mappings for move and copy. Message-ID matching is not an identity-repair substitute.
- Move, archive, and trash require `MOVE` or targeted `UIDPLUS` removal. The adapter must never invoke an unrestricted expunge fallback that could remove unrelated messages.
- UID/UIDVALIDITY reconciliation is the correctness baseline. `CONDSTORE` and `QRESYNC` are optional optimizations whose absence is acceptable only when the provider spike meets the synchronization budget.
- SwiftMail protocol trace and debug output may contain message data, so production logging must discard content-bearing library logs and tests must prove message content cannot reach the production log sink.
- Because SwiftMail's SMTP send API does not expose the failed transaction phase, any error after entering that send call is an ambiguous delivery outcome and is not retried automatically. Connection and authentication failures known to occur before the send call may retain normal retry behavior.
- Pull requests run deterministic local IMAP/SMTP contract tests. Secrets-backed iCloud and Fastmail compatibility tests run only in an opt-in or scheduled environment, supplemented by a documented manual soak checklist.

SwiftMail will handle IMAP and SMTP setup verification as well as runtime operations if it qualifies, avoiding duplicate protocol stacks. The existing stream implementation remains only for POP3, which SwiftMail does not support. iCloud Mail and Fastmail are certified providers; manually configured servers receive compatibility-based support.
