---
status: accepted
---

# Stage mail-engine adoption before provider certification

The exact SwiftMail 1.11.0 release has entered the production dependency graph behind the product-owned Mail Engine boundary after passing the complete deterministic Mail Engine contract, without waiting for paid or secrets-backed provider accounts. That adoption gate comprises the candidate adapter passing `MailEngineQualificationTests.swift` unchanged plus every deterministic MIME, search, mutation, privacy, logging, and performance case required by ADR 0027. Issue [#280](https://github.com/unwired-dev/product/issues/280) now records passing live iCloud Mail and Fastmail qualification evidence, so Standards-Based Mailbox Connections that depend on SwiftMail are accepted for externally distributed production Release builds. Deterministic failures still block dependency or adapter changes, and the product will not ship a fork, patch, handwritten IMAP or SMTP fallback, automatic retry of ambiguous SMTP delivery, unrestricted expunge, or content-bearing protocol logs.

SwiftMail and its adapter run in the Apple/on-device Mail Engine boundary. The TypeScript/Convex backend remains limited to operational account data, encrypted sync blobs, device records, and push metadata; it must not become a mailbox sync engine or make protocol-level decisions.

Live-provider validation moved from a dependency-adoption gate to a release-certification gate. The iCloud Mail and Fastmail scenario, performance, cleanup, and manual-soak requirements passed for SwiftMail 1.11.0. A failed provider spike for a future candidate or pin keeps that capability disabled while the product fixes the adapter, waits for upstream, or replaces the engine.

The Google Workspace Provider Test Tenant and Provider Test Project serve the separate Gmail API compatibility lane. Their paid provisioning is deferred until Gmail release compatibility is scheduled and does not block the approved SwiftMail dependency, generic IMAP/SMTP implementation, or deterministic Local Mail Test Environment work. When that lane starts, ADR 0038 and ADR 0039 still require isolated, synthetic-only infrastructure rather than a personal account, production tenant, or temporary external OAuth workaround.

## Implementation status

Issue [#66](https://github.com/unwired-dev/product/issues/66) completed the runtime adoption: SwiftMail owns IMAP and SMTP setup, transport, protocol parsing, MIME, IDLE, mutations, and submission. Product-owned services retain durable action queues, role and capability policy, stable identity, encrypted Sent-copy recovery, and UI failure state. The handwritten IMAP and SMTP transports were removed; only the legacy POP3 stream remains. Issue [#280](https://github.com/unwired-dev/product/issues/280) completed external Release qualification for iCloud Mail and Fastmail.

## Consequences

- Issue sequencing distinguishes implementation readiness from release certification instead of treating them as one gate.
- Pull requests must keep deterministic Mail Engine qualification green before SwiftMail is pinned or changed.
- Release configuration must fail closed whenever the current exact pin lacks required provider certification; SwiftMail 1.11.0 has that certification.
- Product documentation and UI may describe iCloud Mail and Fastmail as certified for SwiftMail 1.11.0, but must not extend that claim to Gmail or custom IMAP/SMTP servers without corresponding live evidence.
