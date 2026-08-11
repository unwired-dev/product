# IMAP and SMTP protocol-engine offload

Research date: 2026-07-28

Status update: 2026-07-31

Decision update: [ADR 0047](../adr/0047-stage-mail-engine-adoption-before-provider-certification.md) supersedes this research's original sequencing. SwiftMail 1.10.0 is now the approved runtime dependency and issue [#66](https://github.com/unwired-dev/product/issues/66) removed the handwritten IMAP/SMTP transports; live provider evidence remains required before default production enablement. The candidate comparisons and recommendations below are retained as historical decision input.

## Executive answer

Yes: the product can and should offload IMAP, SMTP, TLS, SASL, MIME framing,
response parsing, and connection lifecycle to a library. The current handwritten
transport is still read-oriented and comparatively small, so replacing it before
provider mutations and sending expand is the right time.

No reviewed library is an unchanged, production-ready fit for every current
acceptance gate.

The historical recommendation was:

1. **Retain ADR-0027's architecture boundary.** The library owns protocols; the
   product owns durable sync, identity, retry, reconciliation, privacy, and
   capability policy.
2. **Qualify the exact SwiftMail 1.10.0 tag as the leading native candidate.**
   It now exposes the full IMAP `COPYUID` payload and typed SMTP submission
   outcomes needed to preserve delivery ambiguity, and its manifest uses tagged
   dependency ranges instead of the revision-pinned transitives that blocked
   clean adoption at 1.8.0. It is eligible for deterministic qualification and
   experimental adoption; live certification is still pending.
3. **Keep direct libEtPan 1.10.1 as the fallback spike.** Its public APIs expose
   the same required protocol information, but adopting it would add a Swift/C
   adapter and more product-owned connection behavior. Run this spike only if
   SwiftMail 1.10.0 fails the executable qualification gates.
4. **Evaluate Chilkat only as a commercial fallback.** It is directly usable
   from Swift through Objective-C and is actively shipped, but its documented
   copy/move APIs return only success and its SMTP failure model does not tell a
   caller whether `ConnectionLost`/`Timeout` occurred before or after message
   content crossed the ambiguity boundary.
5. **Do not introduce Rust for this replacement today.** The available Rust
   crates are useful components, not a complete MailKit-like engine. Combining
   them adds a second toolchain, an FFI/XCFramework boundary, and product-owned
   orchestration while still failing the UID-mapping gate.

MailKit is the feature-completeness benchmark. It is not a viable dependency for
this Apple-first Swift application because it is a .NET assembly: using it would
mean embedding and servicing a .NET runtime/AOT build and a custom native
interop layer, or rewriting the app around .NET. That is disproportionate to
the protocol code it would replace.

## What can be replaced

The present implementation hand-builds IMAP and SMTP command flows on
`URLSessionStreamTask`:

- [`SystemIMAPMailboxClient.swift`](../../apps/unwired-mail/unwired-mail/Services/Mailbox/SystemIMAPMailboxClient.swift)
  owns IMAP login, command framing, response parsing, metadata paging, and body
  decoding.
- [`SystemGenericMailEndpointVerifier.swift`](../../apps/unwired-mail/unwired-mail/Services/Mailbox/SystemGenericMailEndpointVerifier.swift)
  owns IMAP/SMTP/POP endpoint negotiation, STARTTLS/implicit TLS, authentication,
  and mailbox-role discovery.
- [`IMAPMailboxConnectionAdapter.swift`](../../apps/unwired-mail/unwired-mail/Services/Mailbox/IMAPMailboxConnectionAdapter.swift)
  currently exposes only generic IMAP reading; search, push, mutations, and send
  remain unsupported.
- [`OutboxDeliveryService.swift`](../../apps/unwired-mail/unwired-mail/Services/Mailbox/OutboxDeliveryService.swift)
  already owns the durable product-level treatment of ambiguous delivery.

A qualified engine can replace the first two files' protocol mechanics and later
back the unsupported adapter capabilities. It must not replace or absorb the
outbox state machine, durable sync model, provider identity, mailbox-role policy,
or privacy boundary.

This is a favorable migration point: there is little mature mutation/send code
to discard, and adopting an engine now avoids deepening the handwritten parser.

## Required capability profile

The evaluation uses the following gates rather than equating a long README
feature list with production suitability.

### IMAP

- IMAP4rev1 interoperability; IMAP4rev2 is desirable, not required for the first
  generic-provider release.
- `IDLE`, `UIDPLUS`, `MOVE`, `SPECIAL-USE`, and Unicode mailbox handling.
- `CONDSTORE`/`QRESYNC` for efficient incremental sync where a server offers
  them, with a correct full-diff fallback.
- Public access to destination `UIDVALIDITY` and ordered source/destination UID
  sets from `COPYUID`.
- Safe targeted deletion: native `UID MOVE`, or `UID COPY` + `UID STORE` +
  `UID EXPUNGE`; never an unrestricted `EXPUNGE` fallback.
- TLS, certificate/hostname verification, SASL `PLAIN`/`LOGIN`, and XOAUTH2 or a
  sufficiently general SASL API.
- Streaming or bounded parsing, cancellation, connection isolation, and safe
  handling of unsolicited responses.

### SMTP and MIME

- Implicit TLS and required STARTTLS with certificate/hostname verification.
- SMTP AUTH including XOAUTH2; `8BITMIME` and MIME attachment/body support.
- `SMTPUTF8` and DSN are desirable for a fully featured engine.
- A public outcome that distinguishes:
  - failure before message content is accepted for transfer;
  - explicit final `4xx`;
  - explicit final `5xx`; and
  - connection loss while sending content or awaiting the final reply, which is
    ambiguous and must not be automatically retried.
- Streaming or bounded message construction, cancellation, and connection reuse
  or pooling where it is safe.

### Operational and supply-chain

- An exact auditable release, maintained upstream, with an acceptable license.
- Apple device and simulator support without private APIs.
- Deterministic provider-fixture tests and measurable compliance with
  [ADR-0018](../adr/0018-local-mail-performance-budget.md).
- Credentials and message data are absent from ordinary logs and error
  telemetry.

No library can be called “secure” or “fast” from its language or README alone.
The final decision requires dependency auditing, adversarial protocol fixtures,
memory/latency measurement, cancellation tests, and TLS downgrade/certificate
tests on the exact artifact.

## Decision matrix

Legend: **Yes** means the documented public API satisfies the gate; **Partial**
means an adapter or reduced capability can satisfy it without editing the
library; **No** means the public boundary loses required information; **Unknown**
means public primary documentation did not establish support.

| Candidate                                          | IMAP sync and extensions                                                                                                                             | Verifiable copy/move identity                                                                                                                                   | SMTP, MIME, and submission outcome                                                                                                                                                                                                          | Apple integration / maintenance                                                                                                                                           | Decision                                                                                                    |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| **MailKit 4.16+ + MimeKit (.NET)**                 | **Benchmark.** IDLE, UIDPLUS, CONDSTORE, QRESYNC, MOVE, SPECIAL-USE, UTF8 and many more; cancellable async APIs                                      | Returns a `UniqueIdMap` for UID moves when available; mature UID-oriented API                                                                                   | SMTPS, STARTTLS, OAuth/SASL, DSN, SMTPUTF8, pipelining, streaming MIME; command exceptions preserve server status, but monolithic send still needs conservative ambiguity handling for I/O failure                                          | Active, MIT, security policy; requires a .NET runtime/AOT and custom Swift interop rather than SwiftPM                                                                    | **Feature benchmark only; reject for this Swift app**                                                       |
| **SwiftMail 1.10.0 (Swift)**                       | IMAP4rev1, IDLE, UIDPLUS, MOVE, SPECIAL-USE, ESEARCH; **no** CONDSTORE, QRESYNC, or UTF8=ACCEPT in its own capability table                          | **Yes when emitted.** Public copy/move APIs return ordered source/destination pairs plus destination `UIDVALIDITY`; absence is distinct from a verified mapping | TLS, XOAUTH2, MIME and SMTP; typed send results and errors preserve phase, explicit final reply, acceptance certainty, and retry disposition; SMTPUTF8 and DSN are not documented                                                           | Native Swift/NIO, BSD-2; exact 1.10.0 tag published July 2026 with tagged dependency ranges and iOS 15/macOS 12 floors                                                    | **Preferred candidate; exact-tag qualification pending**                                                    |
| **libEtPan 1.10.1 (C)**                            | Mature IMAP/SMTP/MIME engine; broad extension support, but a Swift adapter must own async scheduling, cancellation, and high-level connection policy | **Yes when the server emits `COPYUID`.** Public functions return destination `UIDVALIDITY` plus ordered source and destination UID sets for COPY and MOVE       | **Yes with low-level calls.** Public `MAIL`, `RCPT`, `DATA`, and message/final-response phases plus numeric reply code permit safe classification                                                                                           | Active BSD-3 C project; Xcode iOS/macOS targets; exact 1.10.1 tag lacks the SwiftPM manifest now on `master`; no published security policy                                | **Fallback spike only if SwiftMail 1.10.0 fails qualification; adoption still requires full qualification** |
| **Chilkat 11.5.0 (commercial Objective-C binary)** | Broad IMAP, OAuth2, TLS, IDLE, MIME, cancellation/task APIs; rev2/QRESYNC support was not established from public Objective-C docs                   | **No typed mapping.** `Copy`/`CopyMultiple` return `BOOL`; `LastResponse` could be reparsed, but that reintroduces product-owned IMAP parsing                   | Rich SMTP/MIME, TLS, XOAUTH2 and DSN. `SmtpFailReason` distinguishes several commands and generic connection loss, but not whether loss/timeout happened before or after content; logs are diagnostic strings, not a durable typed contract | Current iOS/Swift static binaries, checksums and 30-day evaluation; proprietary bundle license, bridging-header/manual static-library integration, no public source audit | **Commercial fallback only; public APIs fail two hard gates**                                               |
| **swift-nio-imap 0.4.0 + libEtPan SMTP (Swift/C)** | Low-level IMAP grammar/state building block; IDLE and extension representation; upstream says it is pre-production                                   | **Yes when emitted.** `ResponseCodeCopy` preserves destination `UIDVALIDITY` and ordered ranges                                                                 | libEtPan can meet the SMTP outcome gate; MIME/high-level session behavior must be assembled                                                                                                                                                 | Swift 6 / Apache-2; Apple-supported project, but two engines and substantial product-owned orchestration                                                                  | **Useful upstream component, not the desired complete engine**                                              |
| **async-imap 0.11.3 + lettre 0.11.22 (Rust)**      | Active async IMAP4rev1 client; IDLE and CONDSTORE; QRESYNC/rev2 not documented                                                                       | **No.** Public `uid_copy`/`uid_mv` return success without `COPYUID` mapping                                                                                     | lettre is active, async, TLS, OAuth and pooled; its low-level connection can expose SMTP phases, but SMTPUTF8/DSN are not documented and a MIME/IMAP orchestration layer is still needed                                                    | MIT/Apache; requires Rust cross-compilation, static libraries/XCFramework, generated Swift binding, runtime/executor policy, cancellation/error/panic bridging            | **Good components, worse total fit than native C/Swift**                                                    |
| **imap-client 0.3.1 + lettre (Rust)**              | New tokio client over `imap-next`; exposes common capabilities but has partial API documentation and a young 0.3 surface                             | Mapping support was not established                                                                                                                             | Same lettre properties above                                                                                                                                                                                                                | Same FFI burden; two young/independent protocol surfaces                                                                                                                  | **Spike-only ecosystem signal; reject for production now**                                                  |
| **MailCore2 0.6.4 / Postal**                       | Older Apple-native wrappers; incomplete/stale extension and toolchain posture                                                                        | MailCore2/Postal expose partial UID dictionaries but discard destination `UIDVALIDITY`; Postal has no complete copy/SMTP engine                                 | MailCore2's monolithic send loses the pre/post-content stage; Postal has no SMTP                                                                                                                                                            | Last releases 2020/2017 and last source activity 2022/2019 respectively                                                                                                   | **Reject**                                                                                                  |

## Candidate evidence

### MailKit is the benchmark, not an Apple dependency

MailKit's feature list is the clearest definition of “fully featured” among the
reviewed projects: IMAP supports `IDLE`, `UIDPLUS`, `CONDSTORE`, `QRESYNC`,
`MOVE`, `SPECIAL-USE`, and UTF8 extensions; SMTP supports DSN, STARTTLS,
SMTPUTF8, pipelining, chunking, cancellable async operations, and a broad SASL
set including XOAUTH2 ([project feature list](https://github.com/jstedfast/MailKit#features)).
UID-oriented move returns a `UniqueIdMap` where available
([API](https://mimekit.net/docs/html/M_MailKit_IMailFolder_MoveTo_1.htm)).
Its SMTP API returns the final response and separately exposes command response
status through `SmtpCommandException`, although a generic `IOException` from
the monolithic send still does not by itself prove whether content crossed the
ambiguity boundary
([send API](https://mimekit.net/docs/html/M_MailKit_Net_Smtp_SmtpClient_SendAsync.htm),
[exception properties](https://mimekit.net/docs/html/Properties_T_MailKit_Net_Smtp_SmtpCommandException.htm)).

MailKit is active, MIT-licensed, has a published security policy, and has
thousands of commits. Its value here is as a conformance target and a source of
test cases, not as a dependency.

The integration mismatch is fundamental. MailKit is distributed as a NuGet
assembly. Microsoft's iOS guidance describes .NET iOS/MAUI applications that
ship Mono AOT or a statically linked NativeAOT runtime, including its garbage
collector and type system; release builds are whole-app AOT/trimming workflows,
not a drop-in Swift package
([Microsoft runtime and compilation guide](https://learn.microsoft.com/en-us/dotnet/maui/deployment/runtimes-compilation?view=net-maui-10.0)).
Making MailKit callable from the existing Swift app would require maintaining a
.NET iOS build, native exports, object/error/async marshaling, and runtime
servicing. That is more architectural risk than the protocol engine removes.

### SwiftMail 1.10.0 is eligible for qualification

SwiftMail's capability table reports IMAP4rev1, `IDLE`, `UIDPLUS`, `MOVE`,
`SPECIAL-USE`, `ESEARCH`, SASL-IR, TLS and XOAUTH2, while marking `CONDSTORE`,
`QRESYNC`, `ENABLE`, `LIST-STATUS`, and UTF8 acceptance unsupported
([README](https://github.com/Cocoanetics/SwiftMail/blob/1.10.0/README.md)).
It uses SwiftNIO and offers a high-level IMAP/SMTP/MIME surface.

Release 1.8.0 was not adoptable because two public-boundary gaps remained:

- copy and move parse but do not return the server's `COPYUID` result
  ([SwiftMail #194](https://github.com/Cocoanetics/SwiftMail/issues/194));
- send does not expose whether a transport error happened before or after SMTP
  content submission
  ([SwiftMail #195](https://github.com/Cocoanetics/SwiftMail/issues/195)).

It also had a release-engineering blocker. The 1.8.0
[`Package.swift`](https://github.com/Cocoanetics/SwiftMail/blob/1.8.0/Package.swift)
revision-pins `swift-nio-imap` and `swift-nio-ssl`. SwiftPM cannot resolve such
revision-pinned transitive dependencies when the parent is consumed through a
version requirement.

[Release 1.10.0](https://github.com/Cocoanetics/SwiftMail/releases/tag/1.10.0)
resolves both upstream issues. Its public [`CopyUID`](https://github.com/Cocoanetics/SwiftMail/blob/1.10.0/Sources/SwiftMail/IMAP/Models/CopyUID.swift)
model preserves destination `UIDVALIDITY` and ordered source-to-destination
pairs while representing an omitted server mapping as `nil`. Its public
[`SMTPSendError`](https://github.com/Cocoanetics/SwiftMail/blob/1.10.0/Sources/SwiftMail/SMTP/SMTPSendError.swift)
preserves submission phase, acceptance certainty, an explicit final reply when
available, and retry disposition; non-reply failures after content dispatch are
classified as ambiguous. The exact tag's
[`Package.swift`](https://github.com/Cocoanetics/SwiftMail/blob/1.10.0/Package.swift)
uses version requirements for its transitive packages and supports platform
floors below this application's iOS 17 and macOS 14 targets.

These changes remove the upstream adoption prerequisites; they do not prove the
exact tag satisfies the complete ADR-0027 contract. Before the dependency is
pinned experimentally, deterministic qualification must still validate malformed
and missing mappings, connection isolation, TLS and authentication, logging
containment, MIME behavior, and synchronization budgets. The iCloud Mail and
Fastmail provider spikes remain required before default production enablement.

### Direct libEtPan preserves the important information

libEtPan's public UIDPLUS functions expose `uidvalidity_result`,
`source_result`, and `dest_result` for COPY, UID COPY, MOVE, and UID MOVE
([header](https://github.com/dinhvh/libetpan/blob/e79e9b5e2cc61778ead1425b334209d96e1af49f/src/low-level/imap/uidplus.h#L45-L75)).
The implementation obtains those values from the parsed server response
([implementation](https://github.com/dinhvh/libetpan/blob/e79e9b5e2cc61778ead1425b334209d96e1af49f/src/low-level/imap/uidplus.c#L103-L211)).
The adapter can therefore validate source equality, pair cardinality/order and
destination UID validity without parsing response strings.

Its SMTP API separates `MAIL FROM`, `RCPT TO`, `DATA`, and content/final reply
([header](https://github.com/dinhvh/libetpan/blob/e79e9b5e2cc61778ead1425b334209d96e1af49f/src/low-level/smtp/mailsmtp.h#L91-L108)).
`mailsmtp_data()` obtains the `354`; `mailsmtp_data_message()` writes content
and reads the final reply
([implementation](https://github.com/dinhvh/libetpan/blob/e79e9b5e2cc61778ead1425b334209d96e1af49f/src/low-level/smtp/mailsmtp.c#L391-L459));
the session exposes the numeric response
([type](https://github.com/dinhvh/libetpan/blob/e79e9b5e2cc61778ead1425b334209d96e1af49f/src/low-level/smtp/mailsmtp_types.h#L104-L139)).
The adapter can safely classify a pre-`DATA` error, explicit final 4xx/5xx, and
any stream failure in the content/final-response phase as ambiguous. It must
not call the convenience `mailsmtp_send()`, because that collapses the phases.

libEtPan is BSD-3-Clause, provides iOS/macOS Xcode targets, and released 1.10.1
in June 2026
([license](https://github.com/dinhvh/libetpan/blob/e79e9b5e2cc61778ead1425b334209d96e1af49f/COPYRIGHT),
[Apple build instructions](https://github.com/dinhvh/libetpan/blob/e79e9b5e2cc61778ead1425b334209d96e1af49f/README.md#L36-L59),
[release](https://github.com/dinhvh/libetpan/releases/tag/1.10.1)).
Its repository has no published security policy and GitHub lists no project
security advisories; the latter is not evidence that a C protocol parser is
vulnerability-free
([security page](https://github.com/dinhvh/libetpan/security)).
Production qualification therefore needs an explicit vulnerability-reporting
and update plan plus sanitizer, fuzz, and malformed-input coverage for the exact
compiled artifact.
The release does not include the SwiftPM manifest present on `master`, so the
spike should use the tagged Xcode/static-library path and must prove device and
simulator packaging. The synchronous C API belongs on isolated executors; the
Swift wrapper must implement cancellation by closing/aborting the owned
connection and must never share one session concurrently.

### Chilkat is viable to integrate, but not proven to preserve semantics

Chilkat publishes current Objective-C/C/C++ static libraries for iOS, watchOS
and tvOS with checksums and a 30-day evaluation. Its Swift instructions use an
Objective-C bridging header and static link
([downloads](https://www.chilkatsoft.com/downloads_ios.asp),
[Swift linking](https://www.chilkatsoft.com/chilkatSwiftIos.asp)).
Its mail classes document TLS/STARTTLS, certificate state, OAuth2/XOAUTH2,
MIME, DSN, async tasks/cancellation, persistent SMTP connections, and redaction
of credentials from session diagnostics
([SMTP API](https://www.chilkatsoft.com/refdoc/objcCkoMailManRef.html),
[IMAP API](https://www.chilkatsoft.com/refdoc/objcCkoImapRef.html),
[MIME/email API](https://www.chilkatsoft.com/refdoc/objcCkoEmailRef.html)).

The two critical shortcomings are public-result shape, not raw capability:

- `Copy` and `CopyMultiple` return `BOOL`. `LastResponse` and session logs may
  contain `COPYUID`, but parsing a raw diagnostic string would recreate part of
  the IMAP parser, rely on mutable “last call” state, and risk sensitive logging.
  No documented typed API returns destination `UIDVALIDITY` plus both UID sets.
- `SendEmail` returns `BOOL`; `LastSmtpStatus` and `SmtpFailReason` distinguish
  explicit server failures such as `FromFailure`, `DataFailure`, and generic
  `ConnectionLost`/`Timeout`
  ([documented failure values](https://www.chilkatsoft.com/refdoc/objcCkoMailManRef.html#prop68)).
  The latter two do not reveal whether content had begun or the client was
  awaiting the final reply. `SmtpSessionLog` can aid diagnostics but is not a
  typed, concurrency-safe durable outcome.

Before paying for or embedding the binary, ask Chilkat for a supported public
API that returns parsed `COPYUID` data and an SMTP transaction-stage marker for
transport failures. A vendor demonstration against the deterministic failure
fixtures, plus license/update/SBOM/security-response terms, would be required.
Without that evidence, commercial support does not compensate for the missing
semantics.

### Rust does not currently reduce total owned complexity

`async-imap` is active and asynchronous, with IDLE and CONDSTORE support, but
its documented `uid_copy`/`uid_mv` operations return `Result<()>`, losing the
`COPYUID` map
([API](https://docs.rs/async-imap/0.11.3/async_imap/struct.Session.html),
[release history](https://github.com/chatmail/async-imap/blob/main/CHANGELOG.md)).
`imap-next` is intentionally a sans-I/O foundation, and `imap-client` is a
young higher layer rather than a complete engine
([imap-next README](https://github.com/duesee/imap-next),
[imap-client docs](https://docs.rs/imap-client/0.3.1/imap_client/)).

For SMTP, lettre is active, asynchronous, pooled, supports implicit/required
STARTTLS and XOAUTH2, and exposes a low-level `SmtpConnection` on which an
adapter can issue envelope, `DATA`, and message operations
([SMTP transport](https://docs.rs/lettre/0.11.22/lettre/transport/smtp/),
[low-level connection](https://docs.rs/lettre/0.11.22/lettre/transport/smtp/client/struct.SmtpConnection.html)).
Its 0.11.22 release urgently fixed inverted hostname verification in the Boring
TLS backend, so production would have to pin at least that version and select
and audit a TLS backend deliberately
([release](https://github.com/lettre/lettre/releases/tag/v0.11.22)).

Rust itself is compatible with Apple, but compatibility is not free integration.
UniFFI can generate a C header/module map and a Swift API, including async
bridging, and can generate XCFramework-compatible module maps
([Swift binding overview](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html),
[XCFramework generation](https://mozilla.github.io/uniffi-rs/next/swift/uniffi-bindgen-swift.html)).
Its Swift 6 support remains partial, including known async `Sendable` gaps. The
product would additionally own Rust toolchain pinning, per-architecture builds,
binary packaging, executor/runtime policy, cancellation, error/panic mapping,
and auditing of two protocol crates. That is justified only if a Rust engine
materially exceeds the native choices; none reviewed does.

## Protocol limits and ADR impact

### Retain ADR-0027, with two amendments

[ADR-0027](../adr/0027-qualified-third-party-mail-protocol-engine.md) has the
right ownership split and should remain accepted. Amend its qualification text
in two places:

1. Add supply-chain gates: an exact tagged artifact, stable tagged transitives,
   reproducible device/simulator builds, license/SBOM inventory, an upstream
   security-reporting channel, and a documented upgrade SLA.
2. Replace any requirement that a `MOVE`-without-`UIDPLUS` server yield an
   immediate verified destination UID mapping with capability-reduced behavior.

The second change reflects the protocol, not a library weakness. RFC 6851 says
servers supporting UIDPLUS **should** return `COPYUID` for `UID MOVE`; it does
not make UIDPLUS a prerequisite for MOVE
([RFC 6851 §4.3](https://www.rfc-editor.org/rfc/rfc6851.html#section-4.3)).
RFC 4315 defines `COPYUID` as destination `UIDVALIDITY`, ordered source UIDs,
and destination UIDs, and also permits omission for inaccessible or
non-persistent destination mailboxes
([RFC 4315 §3](https://www.rfc-editor.org/rfc/rfc4315.html#section-3)).

Therefore no library can always create that map for a server advertising MOVE
without UIDPLUS. The safe policy is:

- if a verified mapping is required for durable identity, enable move/archive/
  trash only when a native MOVE or safe UIDPLUS sequence returns valid
  `COPYUID`;
- otherwise keep read, search, flag changes, and send available while reporting
  move/archive/trash as unsupported for that server;
- do not infer identity from Message-ID alone and do not use unrestricted
  expunge;
- if product research later accepts delayed destination reconciliation as a
  separate operation, specify and test that as a new architecture decision
  rather than hiding it inside the engine.

This turns an impossible universal mapping gate into an explicit compatibility
tier without weakening deletion safety.

### Reconcile ADR-0026 with the “secure” requirement

[ADR-0026](../adr/0026-allow-legacy-tls-versions.md) allows TLS 1.0+ for
compatibility. That conflicts with claiming a secure default in 2026. RFC 8314
requires mail access and submission servers to support TLS 1.2 or later and
calls for transition away from TLS 1.0
([RFC 8314 §4](https://www.rfc-editor.org/rfc/rfc8314.html#section-4)).

Amend policy so certified/default configurations require TLS 1.2+ with hostname
and chain verification. If legacy TLS remains a product requirement, make it an
explicit per-server user opt-in with a persistent warning, no silent downgrade,
and telemetry that contains no host credentials or message data. The engine
must expose enough TLS configuration to enforce that policy.

## Migration plan

### Phase 0: freeze the boundary

Define one Swift protocol-engine façade before selecting an implementation. Its
results should include:

- connection and negotiated capability snapshot;
- typed authentication/TLS failure;
- incremental-sync changes and reset/full-diff requirement;
- verified copy/move mapping with both mailbox identities, destination
  `UIDVALIDITY`, and ordered UID pairs;
- SMTP result: `notSubmitted`, `transientRejected(code)`,
  `permanentlyRejected(code)`, `accepted`, or `ambiguous`;
- raw MIME streams/data without engine-specific model types escaping upward.

This façade is not a new mail protocol implementation. It protects product code
from C/Swift/Rust/vendor object models and makes candidates interchangeable in
fixtures.

### Phase 1: libEtPan vertical slice

Build a disposable adapter against the exact 1.10.1 tag and prove, in order:

1. iOS device, Apple-silicon simulator, and macOS builds;
2. implicit TLS and required STARTTLS, certificate/hostname failure, TLS policy,
   LOGIN/PLAIN, and XOAUTH2;
3. LIST/SPECIAL-USE, SELECT, paged UID metadata, partial/full MIME, and IDLE;
4. COPY, native MOVE, and copy/store/UID-expunge with strict `COPYUID`
   verification and negative/malformed fixtures;
5. SMTP envelope rejection, `DATA` rejection, final 4xx/5xx, disconnect while
   writing content, and disconnect while awaiting the final response;
6. cancellation, one-session ownership, bounded memory, log redaction, and
   ADR-0018 measurements.

Reject the candidate if the adapter must parse raw IMAP/SMTP diagnostic strings,
cannot cancel safely, silently downgrades TLS, or cannot meet the memory/main-
thread budgets.

### Phase 2: shadow and replace

Use the engine first for endpoint verification and read-only listing/fetching
behind the existing adapter. In fixture and development builds, compare its
normalized results against the present client. Then switch reads, enable
incremental sync/IDLE, enable only capability-qualified mutations, and finally
connect the SMTP result to the existing outbox ambiguity model.

Delete the handwritten framing/parser only after provider fixtures and stored
message samples reach parity. Keep no fallback that silently returns to the old
wire code; two protocol engines would double the security and correctness
surface.

### Phase 3: production qualification

Before shipping:

- pin the exact source/artifact and record hashes, licenses, transitive
  dependencies, compiler settings, and update process;
- run iCloud, Fastmail, Gmail, Outlook, and adversarial deterministic fixtures;
- fuzz/parser-test malformed lengths, literals, unsolicited responses, response
  interleaving, MIME nesting, invalid Unicode, and oversized headers;
- test TLS downgrade, bad chain, hostname mismatch, expired/revoked certificate
  behavior, auth-log redaction, and token expiry;
- measure large-mailbox sync, large attachment streaming, IDLE lifetime,
  connection churn, memory, energy, and cancellation;
- document the capability-reduced UX for servers without a trustworthy
  destination mapping.

## Final recommendation

The historical recommendation was deterministic qualification before experimental adoption.
ADR 0047 records that adoption; provider certification is now the remaining gate:

- **Primary:** retain the adopted SwiftMail 1.10.0 tag and certify both live providers
  before default production enablement.
- **Fallback:** time-box direct libEtPan 1.10.1 behind a thin Swift façade only
  if SwiftMail fails qualification.
- **Commercial fallback:** Chilkat only if the vendor exposes and supports typed
  COPYUID and SMTP-stage results.
- **Benchmark:** MailKit/MimeKit for capability coverage and test design.
- **Do not pursue now:** Rust combinations, MailCore2, Postal, or more
  handwritten protocol code.

This offloads the difficult standards work while preserving the two product
semantics a generic library cannot own: stable local identity and safe retry
under uncertain delivery.
