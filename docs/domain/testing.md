# Mail testing

[Domain index](../../CONTEXT.md) · [testing policy](../agents/testing.md) and [mail test environment](../mail-test-environment.md)

Mock Mail Sessions and real integration evidence serve different purposes under
[ADR 0060](../adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md).
The legacy harness terms do not establish replacement-host qualification.

Each term has one canonical definition in this glossary collection. Use the
[documentation index](../README.md) and
[ADR 0059](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
for launch scope; a term's presence does not establish implementation or release.

## Language

**Local Mail Test Environment**:
A disposable, developer-controlled mail system used to exercise the product against realistic mailbox behavior without contacting an external **Mail Provider**.
_Avoid_: Mock mailbox, production provider

**Provider Test Mailbox**:
A non-production mailbox hosted by a real **Mail Provider** and reserved for provider-compatibility testing.
_Avoid_: Personal mailbox, user mailbox

**Provider Test Tenant**:
An organization-controlled, synthetic-only provider domain containing **Provider Test Mailboxes** and isolated from personal and production identities.
_Avoid_: Production tenant, personal provider account

**Provider Test Project**:
An isolated provider-platform project whose authorization, API quotas, event routes, and credentials exist only to support compatibility testing against a **Provider Test Tenant**.
_Avoid_: Production provider project, shared provider credentials

**Mailbox Scenario**:
A named, repeatable arrangement of messages, mailboxes, and mailbox state that local and provider test environments can instantiate with explicit capability-specific expectations.
_Avoid_: Test email, ad hoc fixture

**Synthetic Test Message**:
A standards-valid test message whose addresses, content, and assets were created for testing and do not derive from personal or production mail.
_Avoid_: Anonymized production email, copied personal email

**Mock Mail Session**:
An isolated product session whose identity, mail, and assistance responses come from repeatable synthetic scenarios and have no authority over real accounts or mail.
_Avoid_: Provider Compatibility Run, production mailbox, Local Mail Test Environment

**Core Mail Loop**:
The everyday sequence in which a person receives, synchronizes, reads, organizes, composes, sends, and replies to mail while observing the resulting mailbox state.
_Avoid_: Seeded inbox rendering, provider qualification

**Mail Test Run**:
An isolated execution of one **Mailbox Scenario** in a fresh **Local Mail Test Environment**, owned by one automated test or agent and discarded afterward.
_Avoid_: Shared test mailbox, persistent sandbox

**Provider Compatibility Run**:
A serialized execution of a **Mailbox Scenario** against a **Provider Test Tenant** and **Provider Test Project** through protected automation that does not expose reusable provider credentials.
_Avoid_: Mail Test Run, personal-account testing

**Manual Mail Sandbox**:
A persistent **Local Mail Test Environment** reserved for human exploratory testing and kept separate from automated **Mail Test Runs**.
_Avoid_: Automated test environment, shared agent mailbox

**Mail Test Harness**:
The product-owned interface through which humans and automation create, seed, observe, reset, and destroy test mail environments.
_Avoid_: Mail-server administration interface, ad hoc test script

**Mail Test Device**:
A harness-owned non-production app runtime whose app data, credentials, and trust state are isolated for one **Mail Test Run** or **Manual Mail Sandbox**.
_Avoid_: Personal simulator, shared development device

**Test Product Account**:
An isolated non-production **Product Account** identity used only within a **Mail Test Run** and representing neither a real person nor a backend account.
_Avoid_: Personal Product Account, shared test user

**Mail Test Bootstrap**:
The minimum startup configuration that lets a test-only build enter its **Test Product Account** and authorize the mailbox assigned to its **Mail Test Run**.
_Avoid_: In-app test control API, fixture loader

**Mail Test Evidence**:
A redacted, machine-readable record of a **Mail Test Run** or **Provider Compatibility Run** and the app-visible and server-visible outcomes needed to verify or diagnose it.
_Avoid_: Unstructured test log, credential-bearing artifact

**Mail Test Ownership Record**:
A run-bound record that identifies the exact processes, devices, endpoints, and generated state the **Mail Test Harness** is permitted to mutate or destroy.
_Avoid_: Resource-name match, global cleanup rule
