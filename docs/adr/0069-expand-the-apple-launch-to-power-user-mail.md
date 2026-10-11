---
status: accepted
---

# Expand the Apple launch to power-user mail

## Context

The product owner completed the feature-gap interview on 2026-10-11 and
explicitly confirmed the requirements in
[Power-user mail launch](../product/power-user-launch.md). The earlier focused
Gmail release is now an intermediate beta, not the public launch target.
[Documentation #843](https://github.com/unwired-dev/product/issues/843) records
the reconciliation; [launch #844](https://github.com/unwired-dev/product/issues/844)
tracks implementation and qualification. This decision records that confirmed
scope without claiming that the capabilities are implemented.

## Decision

Launch on the maintained iPhone, iPad and Mac hosts with Gmail, IMAP/SMTP and
Microsoft mail. Certify iCloud Mail and Fastmail, allow reviewed manual setup for
compatible standards-based servers, and make no universal compatibility promise.
Microsoft mail covers personal Outlook.com and work/school users' own mailboxes;
shared and delegated mailboxes follow later. POP3 and on-premises Exchange/EWS
remain outside this launch. Google and Apple remain the launch Product Sign-In
Providers. Microsoft mailbox authorization is separate from Microsoft Product
Sign-In and linking, which remain follow-up work.

Serve an individual using multiple Mailbox Connections. Include optional Work
and Personal Mail Profiles, beginning with one Default Profile without forced
setup. Each Profile separates mailbox collections, unified Inbox, search,
sending defaults and notification policy. Profile adoption must preserve existing
connections, Drafts and queued work; it cannot reuse the one-time unused
development-data reset.

Prioritize dependable everyday mail before Catch Up and new AI experiences.
The launch specification owns the complete observable requirements: mailbox
navigation and conversations, reliable delivery and Draft exits, power-user
keyboard and bulk workflows, search, sending identities, templates, Snooze,
reply-aware Follow-Up Nudges, deterministic Mail Rules, notification controls and
native mail workflows. Scheduled Send does not become a launch gate merely
because Snooze and Follow-Up Nudges are included.

Progressively backfill complete provider-visible historical metadata without
blocking initial use. Offline search covers synchronized metadata and downloaded
body content, exposes incomplete coverage, and offers explicit online search for
the remainder. Replace the fixed ordinary-body-cache launch quota with
user-configurable storage controls; this decision chooses no replacement quota.
Keep Offline is an explicit device-local retention request for conversations or
folders, optionally including attachments. Completed retained content survives
ordinary cache eviction until released, subject to the existing deletion and
authorization boundaries. Pin remains a separate workflow preference.

Keep all retained mail encrypted locally and preserve account, Profile,
connection and message isolation. Keep Offline does not authorize remote-image
requests or bypass attachment admission and size limits. Its explicit retention
supersedes ordinary body and attachment eviction only for selected retained
content; the implementation slices must define and qualify storage admission,
failure reporting and cleanup.

Mail Rules execute on trusted devices and catch up when those clients resume,
with visible pending work. Their conditions, historical previews and organization
actions do not imply AI inference, backend-readable mail or always-on provider
execution. Quiet hours and sender/rule notification filtering extend the existing
permission, per-connection, generic-by-default and optional-preview controls.
Notifications still exclude historical synchronization and do not depend on AI
categorization.

The receive, find, read, organize, compose, reply, send and recovery journeys need
real evidence across all launch providers and all three maintained Apple hosts.
Mock journeys and prototype features are not provider or native qualification.
Public store release waits for
[expanded qualification #855](https://github.com/unwired-dev/product/issues/855).
The intermediate Gmail TestFlight milestone does not gate starting the promoted
provider and Profile work.

## Supersession and retained boundaries

This decision supersedes only the affected launch-scope clauses:

- [ADR 0059](0059-replace-the-client-for-a-shared-cross-platform-product.md):
  Gmail-only launch, deferral of optional Profiles and deterministic Mail Rules,
  fixed 500 MB ordinary body-cache launch policy, and provider-only body search.
- [ADR 0060](0060-pair-mocked-mail-journeys-with-real-integration-evidence.md):
  Gmail-only first-release integration scope. Real IMAP/SMTP and Microsoft
  evidence is now required too.
- [ADR 0061](0061-separate-product-identity-from-registration-mailbox-authorization.md):
  Gmail-only mailbox setup scope. Product identity, device trust and each
  provider's verified mailbox consent remain separate.
- [ADR 0006](0006-local-metadata-search-provider-full-text-search.md):
  provider-only full-text search for launch. Downloaded bodies are searchable
  offline without adding a backend-readable index.
- [ADR 0012](0012-bounded-encrypted-body-cache.md) and
  [ADR 0030](0030-gate-incoming-attachment-downloads.md): fixed ordinary-cache
  launch quota and eviction of explicitly retained offline content. Existing
  encryption, resource admission, remote-content consent and cleanup remain.

The privacy, enrollment, recovery, deletion and transport decisions remain in
force. The originating-device Outbox, default 10-second Undo Send, required
content-free atomic Convex send admission and uncertain-outcome protections in
[ADR 0062](0062-keep-queued-delivery-on-its-originating-device.md) apply to every
launch provider. Provider expansion creates no automatic cross-device delivery
takeover, backend-held provider credentials or alternate uncoordinated send path.

The platform floors remain iOS, iPadOS and macOS 27. Host/workspace and Effect
boundaries remain unchanged. Android, Windows, team/CRM workflows, Spotlight,
bulk mailbox import/export, an independent Mac helper and direct Mac distribution
are later work. Existing assistance privacy and enablement decisions remain;
prioritizing reliable mail does not weaken them. Technical design and measurable
verification belong to the implementation slices rather than this scope record.
