# SwiftMail engine dependency

The Apple app approves and pins SwiftMail `1.11.0` at resolved commit
`a2d4a94f844db62843ef6aec16f3ed9462152acc`. Dependency review must compare both values; do
not move the tag, switch to a branch, carry a fork, or add a product-owned IMAP/SMTP fallback.
Issue [#66](https://github.com/unwired-dev/product/issues/66) completed its runtime adoption. Live
provider certification remains the separate release gate in issue
[#280](https://github.com/unwired-dev/product/issues/280).

Link the SwiftMail product only to the app target. The hosted test target intentionally accesses
that module through its app test host: linking SwiftMail to both targets makes Xcode materialize a
dynamic package-product framework whose Release link exposed SwiftMail 1.10.0's missing direct
`SE0270_RangeSet` dependency. SwiftMail 1.11.0 resolves this transitive, but the single-target
linkage remains the approved pattern. The focused engine tests verify that this hosted linkage
remains available.

`ExperimentalSwiftMailEngine` implements the transient, provider-neutral `MailEngine` boundary;
its name reflects release availability, not dependency approval. SwiftMail owns TLS,
authentication, IMAP and SMTP framing, MIME rendering and reads, IDLE, UID operations,
submission, and Sent append. SwiftMail also owns IMAP and SMTP setup verification. Product
services retain persistence, mailbox roles, capability policy, durable retries, reconciliation,
Stable Provider Message Identity, and provider-action policy. The removed product-owned IMAP and
SMTP transports have no runtime fallback; the existing stream verifier remains only for POP3,
which SwiftMail does not support.

## Safety boundary

- TLS uses full certificate and hostname verification with a TLS 1.2 floor, or TLS 1.3 when the
  caller requests it. IMAP and SMTP transport modes remain independently configurable.
- Native move requires the server's `MOVE` capability and a complete validated `COPYUID` mapping.
  The UIDPLUS fallback copies once, durably records the validated mapping, and then targets only
  the exact source UIDs for deletion and `UID EXPUNGE`. Recovery resumes from that record without
  copying again, and local identity follows the server-reported destination UID. The product
  never invokes unrestricted expunge.
- SMTP maps explicit pre-content and final `4xx`/`5xx` failures separately from ambiguous
  post-content outcomes. An ambiguous outcome is not retryable and invalidates the SMTP channel.
- Recipient lists are parsed and validated by the bounded product-owned `RFCMailboxHeaderParser`
  before MIME rendering or SMTP submission. It handles RFC comments, quoted display names, and
  groups while rejecting malformed structure and CR/LF injection. SwiftMail remains the approved
  transport dependency, but its `EmailAddress` is a data container rather than a strict public
  recipient-list parser, so no additional parser dependency is introduced. The Apple app owns this
  validation boundary; TypeScript and Convex neither parse nor validate recipient lists nor receive
  readable recipients or provider execution requests.
- After explicit SMTP acceptance, an encrypted device-local journal retains the exact rendered
  MIME until the mapped Sent mailbox contains it. Recovery searches by stable RFC Message-ID and
  retries only the append; it never repeats the accepted SMTP submission.
- Advertised IDLE runs on a fresh SwiftMail session. Transport loss closes that session and
  reconnects with bounded exponential backoff; callbacks trigger immediate mailbox sync while
  polling remains available as the fallback.
- Read-state and star actions need no optional extension. Move-family actions are exposed only
  when `MOVE` or `UIDPLUS` is verified, and role actions additionally require a trustworthy saved
  mailbox mapping. Provider Draft mail remains read-only; product-authored drafts use the
  product's end-to-end encrypted Draft model.
- The product logger receives only content-free lifecycle events. The adapter never forwards
  SwiftMail protocol traces, credentials, mailbox identifiers, or message content.

## Dependency approval and release availability

The exact dependency and runtime adapter are approved. Debug and test builds can construct the
engine, and an explicitly controlled internal Release build can define
`UNWIRED_INTERNAL_SWIFTMAIL`. Ordinary externally distributed Release builds still fail closed
because `providerCertificationComplete` remains `false` in
`SwiftMailExperimentalBuildPolicy`.

Do not set that value to `true` until issue #280 records passing iCloud Mail and Fastmail
qualification evidence. The approved dependency remains linked while the Standards-Based Mail
capability is unavailable; no external Release setup or Mailbox Connection path selects it.

## Validation

Resolve and verify the exact package pin:

```sh
xcodebuild -resolvePackageDependencies \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail
```

Run Apple formatting, linting, and tests through the repository commands. When mise is not
activated in the shell, prefix the lint command with `mise exec --`:

```sh
zsh scripts/check-apple-lint.zsh
xcodebuild test \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

The reusable deterministic contract remains in `MailEngineQualificationTests.swift`. Protected
provider certification uses the separate runbook in `docs/qualification/swiftmail-provider.md`.
