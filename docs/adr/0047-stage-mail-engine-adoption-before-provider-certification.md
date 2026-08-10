---
status: accepted
---

# Stage mail-engine adoption before provider certification

The exact SwiftMail 1.10.0 release has entered the production dependency graph behind the product-owned Mail Engine boundary after passing the complete deterministic Mail Engine contract, without waiting for paid or secrets-backed provider accounts. That adoption gate comprises the candidate adapter passing `MailEngineQualificationTests.swift` unchanged plus every deterministic MIME, search, mutation, privacy, logging, and performance case required by ADR 0027. Until the live iCloud Mail and Fastmail qualification spikes pass, Standards-Based Mailbox Connections that depend on SwiftMail remain experimental and cannot be enabled in externally distributed production release builds; development, tests, and explicitly enabled internal builds may use them. Deterministic failures still block dependency or adapter changes, and the product will not ship a fork, patch, handwritten IMAP or SMTP fallback, automatic retry of ambiguous SMTP delivery, unrestricted expunge, or content-bearing protocol logs.

SwiftMail and its adapter run in the Apple/on-device Mail Engine boundary. The TypeScript/Convex backend remains limited to operational account data, encrypted sync blobs, device records, and push metadata; it must not become a mailbox sync engine or make protocol-level decisions.

Live-provider validation moves from a dependency-adoption gate to a release-certification gate. The existing iCloud Mail and Fastmail scenario, performance, cleanup, and manual-soak requirements remain mandatory before default production enablement. A failed provider spike keeps the capability disabled while the product fixes the adapter, waits for upstream, or replaces the engine.

The Google Workspace Provider Test Tenant and Provider Test Project serve the separate Gmail API compatibility lane. Their paid provisioning is deferred until Gmail release compatibility is scheduled and does not block the approved SwiftMail dependency, generic IMAP/SMTP implementation, or deterministic Local Mail Test Environment work. When that lane starts, ADR 0038 and ADR 0039 still require isolated, synthetic-only infrastructure rather than a personal account, production tenant, or temporary external OAuth workaround.

## Implementation status

Issue [#66](https://github.com/unwired-dev/product/issues/66) completed the runtime adoption: SwiftMail owns IMAP and SMTP setup, transport, protocol parsing, MIME, IDLE, mutations, and submission. Product-owned services retain durable action queues, role and capability policy, stable identity, encrypted Sent-copy recovery, and UI failure state. The handwritten IMAP and SMTP transports were removed; only the legacy POP3 stream remains. External Release availability still depends on issue [#280](https://github.com/unwired-dev/product/issues/280).

## Consequences

- Issue sequencing distinguishes implementation readiness from release certification instead of treating them as one gate.
- Pull requests must keep deterministic Mail Engine qualification green before SwiftMail is pinned or changed.
- Release configuration must fail closed: externally distributed production builds cannot enable an uncertified Standards-Based capability; only an internal build may opt in.
- Product documentation and UI must not describe iCloud Mail, Fastmail, Gmail, or custom IMAP/SMTP support as certified until the corresponding live evidence exists.
