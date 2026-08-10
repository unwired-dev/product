# Experimental SwiftMail engine

The Apple app pins SwiftMail `1.10.0` at resolved commit
`c907f871bb23812895274f4c7ae17bf343171c1e`. Dependency review must compare both values; do
not move the tag, switch to a branch, carry a fork, or add a product-owned IMAP/SMTP fallback.

`ExperimentalSwiftMailEngine` implements the transient, provider-neutral `MailEngine` boundary.
SwiftMail owns TLS, authentication, IMAP and SMTP framing, selected MIME-part reads, resilient
IDLE, UID operations, submission, and Sent append. Product services retain persistence, mailbox
roles, durable retries, reconciliation, and provider-action policy.

## Safety boundary

- TLS uses full certificate and hostname verification with a TLS 1.2 floor, or TLS 1.3 when the
  caller requests it. IMAP and SMTP transport modes remain independently configurable.
- Copy and move require a complete validated `COPYUID` mapping. The current experimental adapter
  cannot move without UIDPLUS, including on a server that advertises MOVE; it therefore does not
  yet satisfy ADR-0027's MOVE-without-UIDPLUS production acceptance gate. The reduced-capability
  path validates COPYUID before marking the exact source UIDs as deleted and uses only
  `UID EXPUNGE`; it never invokes unrestricted expunge.
- SMTP maps explicit pre-content and final `4xx`/`5xx` failures separately from ambiguous
  post-content outcomes. An ambiguous outcome is not retryable and invalidates the SMTP channel.
- The product logger receives only content-free lifecycle events. The adapter never forwards
  SwiftMail protocol traces, credentials, mailbox identifiers, or message content.

## Experimental and release availability

Debug and test builds can construct the engine. An explicitly controlled internal Release build
can define `UNWIRED_INTERNAL_SWIFTMAIL`. Ordinary externally distributed Release builds fail
closed because `providerCertificationComplete` remains `false` in
`SwiftMailExperimentalBuildPolicy`.

Do not set that value to `true` until issue #280 records passing iCloud Mail and Fastmail
qualification evidence. The dependency may remain linked while the engine is unavailable; no
production setup or Mailbox Connection path selects it during this experimental stage.

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
