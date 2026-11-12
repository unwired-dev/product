# Documentation index

The maintained Expo and native Mac clients include production-provider features
and explicit Mock Mail Sessions. Feature guides below own their current behavior
and limitations. The launch specification owns target scope; GitHub issues own
completion status. Publication of a plan does not prove implementation or release.

## Launch requirements and operations

- [Confirmed power-user launch scope and delivery order](product/power-user-launch.md)
- [Apple system integration and legal readiness decisions](product/apple-system-and-legal-readiness.md)
- [iPhone Duo requirements and delivery](product/iphone-duo.md)
- [Expo bootstrap, stack, setup and checks](expo-client.md)
- [Native Mac windows, setup and checks](macos-client.md)
- [On-demand and nightly TestFlight builds from CI and a Mac](testflight.md)
- [Convex production deploys from CI](convex-deploy.md)

- [Deterministic Mock Mail Sessions and external runners](mock-mail-sessions.md)
- [Native journeys](native-journeys.md)
- [Private preview Inbox storage and credentials](private-inbox-storage.md)
- [Google registration, Gmail consent, production authorization and protected OAuth qualification](google-registration.md)
- [Apple registration, mailbox choice and current Gmail authorization](apple-registration.md)
- [Gmail Inbox synchronization and its encrypted cache](gmail-inbox.md)
- [Microsoft mail connection and Graph Inbox](microsoft-mail.md)
- [IMAP mailboxes: setup, synchronization, reading and SMTP sending](imap-mailboxes.md)
- [On-device message summaries](message-summaries.md)
- [Catch Up, the planned chat-style Inbox, and background summaries](catch-up.md)
- [On-device translation](message-translation.md)
- [On-device Draft rewrites, Writing tools and reply suggestions](draft-assistance.md)
- [Private Cloud Mail Assistance: confirmed planned scope and delivery](product/private-cloud-mail-assistance.md)
- [On-device assistance qualification on physical hardware](assistance-qualification.md)
- [Drafts, the composer and provider-hosted launch work](drafts.md)
- [Tiptap Draft editor evaluation on iPhone, iPad and Mac](draft-editor-evaluation.md)
- [DeBERTa categorization spike on Mac, iPhone and iPad](categorization-spike.md)
- [System Category model benchmark for English and Czech (spike #828)](../tools/system-category-benchmark/README.md)
- [Custom Category model benchmark for English and Czech (spike #829)](../tools/system-category-benchmark/CUSTOM.md)
- [Gmail delegation spike: no supported path for the native grant](gmail-delegation-spike.md)
- [Microsoft mailbox import fidelity spike: IMAP APPEND awaits live proof](microsoft-import-fidelity-spike.md)
- [Browser mail client and extension evaluation: no-go](browser-client-evaluation.md)
- [Assistant inside Gmail and Outlook evaluation: no-go](provider-assistant-evaluation.md)
- [Sending Drafts through the Outbox](outbox.md)
- [Responding to Gmail meeting invitations on Mac, iPhone and iPad](invitation-responses.md)
- [Unsubscribe: finding a message's unsubscribe mechanism](unsubscribe.md)
- [New Mail Notifications](new-mail-notifications.md)
- [Command Palette: finding and running actions from any screen](command-palette.md)
- [Linked Google and Apple sign-in](linked-sign-in.md)
- [Private Sync and the Recovery Key](private-product-sync.md)
- [Sign-out and Product Account deletion](account-removal.md)
- [Interface translations and language preferences](localization.md)
- [Opt-in error reporting and planned analytics](telemetry.md)
- [Draft App Store Connect App Privacy answers](app-privacy.md)
- [Confirmed interaction motion goals and tracked coverage gaps](product/interaction-motion.md)
- [Dedicated Gmail test accounts and protected qualification](gmail-provider-test-tenant.md)

## Post-launch requirements

- [Mail capability expansion: confirmed follow-up requirements](product/mail-capability-expansion.md)
- [Mail Commitments: confirmed future-feature requirements](product/mail-commitments.md)
- [Agent access: confirmed MCP mail access requirements](product/agent-access.md)

## Architecture and evidence

The [architecture index](architecture/README.md) routes extracted companions,
ADRs, patterns, research, qualification evidence and historical sources;
[AGENTS.md](../AGENTS.md) routes agent policies. Review verifies applicable
decisions and deferred release checks under the
[implementation and review workflow](agents/implementation-review.md).
