# Documentation index

The Expo rewrite is approved and ticketed. The Expo mock Inbox and the existing
SwiftUI and Mac Catalyst prototype, plus the native Mac mock Inbox, are executable. Read documents according to
their scope below; publication of a plan does not prove implementation or release.

## Replacement requirements and operations

- [Expo bootstrap, stack, setup and checks](expo-client.md)
- [Native Mac windows, setup and checks](macos-client.md)
- [On-demand and nightly TestFlight builds from CI and a Mac](testflight.md)
- [Convex production deploys from CI](convex-deploy.md)

- [Deterministic Mock Mail Sessions and external runners](mock-mail-sessions.md)
- [Private preview Inbox storage and credentials](private-inbox-storage.md)
- [Google registration, Gmail consent and protected OAuth qualification](google-registration.md)
- [Apple registration continuing into Gmail authorization](apple-registration.md)
- [Gmail Inbox synchronization and its encrypted cache](gmail-inbox.md)
- [On-device message summaries](message-summaries.md)
- [Catch Up, the planned chat-style Inbox, and background summaries](catch-up.md)
- [On-device translation](message-translation.md)
- [On-device Draft rewrites and reply suggestions](draft-assistance.md)
- [Local rich-text Drafts and the composer](drafts.md)
- [Sending Drafts through the Outbox](outbox.md)
- [Linked Google and Apple sign-in](linked-sign-in.md)
- [Private Product Sync and the Recovery Key](private-product-sync.md)
- [Sign-out and Product Account deletion](account-removal.md)
- [Interface translations and language preferences](localization.md)

## Shared policies

- [Root agent guide](../AGENTS.md) and [backend guide](../packages/convex/AGENTS.md)
- [Implement a GitHub issue through PR babysitting](../.agents/skills/implement-issue/SKILL.md)
- [Implementation handoff, pinned OCR and thermo-nuclear review agents](agents/implementation-review.md)
- [Domain vocabulary by topic](../GLOSSARY.md) and [maintenance policy](agents/domain.md)
- [Test admission, retirement, and feedback budgets](agents/testing.md)
- [Effect conventions and lint enforcement](agents/effect.md)
- [Effect service constructors, methods and layers](agents/effect-services.md)
- [Native validation and resource ownership](agents/native-validation.md)
- [GitHub issue workflow and triage labels](agents/issue-tracker.md)
- [Automated reviews and PR babysitting](agents/pull-request-babysitting.md)

The implementer uses this index to find requirements and operational guidance.
Only the review agent opens architecture docs and decision records under the
[implementation and review workflow](agents/implementation-review.md).

## Current Swift maintenance

These operating guides remain useful while the prototype is present. Their
commands and results do not transfer to new hosts.

- [Swift setup and current behavior](swift-client.md)
- [Scoped Swift agent guide](../apps/unwired-mail/AGENTS.md)
- [Mail test environment](mail-test-environment.md)
- [Protected Gmail test tenant](gmail-provider-test-tenant.md)
- [Storage and Product Sync export](storage-and-product-sync-export.md)

## Review handoff

The [reviewer-only architecture index](architecture/README.md) routes extracted
companions, ADRs, patterns, research, qualification evidence and historical sources.
Implementers do not open those files. The reviewer verifies applicable decisions
and deferred release checks under the [handoff workflow](agents/implementation-review.md).

Update affected operational documentation in each implementation slice. At
[cutover #627](https://github.com/unwired-dev/product/issues/627), remove the remaining
Swift implementation, build targets and tests after their replacement slices are
complete. Prototype commands and results do not qualify replacement hosts.
