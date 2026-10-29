# Mail testing

[Domain index](../../GLOSSARY.md) · [testing policy](../agents/testing.md)

Mock Mail Sessions and real integration evidence serve different purposes under
[ADR 0060](../adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md).
The Swift prototype's local mail test harness vocabulary was retired with it in
[#1371](https://github.com/unwired-dev/product/issues/1371).

Each term has one canonical definition in this glossary collection. Use the
[documentation index](../README.md) and
[power-user launch specification](../product/power-user-launch.md)
([ADR 0069](../adr/0069-expand-the-apple-launch-to-power-user-mail.md))
for launch scope; a term's presence does not establish implementation or release.

## Language

**Provider Test Mailbox**:
A non-production mailbox hosted by a real **Mail Provider** and reserved for provider-compatibility testing.
_Avoid_: Personal mailbox, user mailbox

**Provider Test Accounts**:
Project-controlled provider identities reserved for **Provider Test Mailboxes** and **Synthetic Test Messages**, isolated from personal and production use. They may be ordinary consumer accounts without an organization-owned domain.
_Avoid_: Provider Test Tenant, personal provider accounts

**Provider Test Project**:
An isolated provider-platform project whose authorization, API quotas, event routes, and credentials exist only to support compatibility testing with **Provider Test Accounts**.
_Avoid_: Production provider project, shared provider credentials

**Mailbox Scenario**:
A named, repeatable arrangement of messages, mailboxes, and mailbox state that local and provider test environments can instantiate with explicit capability-specific expectations.
_Avoid_: Test email, ad hoc fixture

**Synthetic Test Message**:
A standards-valid test message whose addresses, content, and assets were created for testing and do not derive from personal or production mail.
_Avoid_: Anonymized production email, copied personal email

**Mock Mail Session**:
An isolated product session whose identity, mail, and assistance responses come from repeatable synthetic scenarios and have no authority over real accounts or mail.
_Avoid_: Provider Compatibility Run, production mailbox

**Core Mail Loop**:
The everyday sequence in which a person receives, synchronizes, reads, organizes, composes, sends, and replies to mail while observing the resulting mailbox state.
_Avoid_: Seeded inbox rendering, provider qualification

**Provider Compatibility Run**:
A serialized execution of a **Mailbox Scenario** against **Provider Test Accounts** and a **Provider Test Project** through protected automation that does not expose reusable provider credentials.
_Avoid_: Personal-account testing

**Mail Test Evidence**:
A redacted, machine-readable record of a **Provider Compatibility Run** and the app-visible and server-visible outcomes needed to verify or diagnose it.
_Avoid_: Unstructured test log, credential-bearing artifact
