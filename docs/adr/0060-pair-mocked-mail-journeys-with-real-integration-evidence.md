---
status: accepted
---

# Pair mocked mail journeys with real integration evidence

The replacement client will provide deterministic Mock Mail Sessions with
synthetic identity, mail, and AI behavior, plus a smaller integration suite that
exercises real persistence, native bindings, and provider transport. Mocked UI
journeys support repeatable development and failure scenarios; they do not prove
that real authentication, provider APIs, or platform integrations work.

This explicitly permits simulated provider behavior for replacement-client
testing, superseding the blanket provider-bypass prohibition in
[ADR 0037](0037-keep-mail-test-control-outside-the-app.md) for that test path.
Preserve the test-only isolation and external ownership of scenario selection,
reset, and cleanup. No production credential or real mailbox belongs in a
Mock Mail Session, and the new mode does not authorize a production test-control
server or reset backdoor.

The first release's integration evidence must exercise Gmail's actual transport
and authentication boundaries. Local controlled responses can prove deterministic
Gmail protocol contracts, while protected Gmail test mailboxes supply live
compatibility evidence. Existing GreenMail scenarios may support later IMAP/SMTP
work; they cannot certify the first-release Gmail implementation.

Retire old tests when their implementation or protected behavior is retired.
Retain or replace coverage for data loss, duplicate sends, identity isolation,
encryption, and critical user journeys. Existing backend or provider-contract
coverage is not obsolete merely because the client is being rewritten.
This reaffirms the risk-based admission and retirement rules in
[ADR 0049](0049-use-a-risk-weighted-test-portfolio.md) and
[the testing policy](../agents/testing.md).

The mobile and desktop E2E runners, required scenarios, and validation commands
remain to be qualified against the selected application hosts. The current
implementation's required checks remain in force until their replacements exist.
