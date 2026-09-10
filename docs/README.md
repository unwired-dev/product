# Documentation index

The Expo rewrite is approved and ticketed. The current executable application
is still the SwiftUI and Mac Catalyst prototype. Read documents according to
their scope below; publication of a plan does not prove implementation or release.

## Replacement decisions and work

- [Accepted product and platform scope](adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
- [Mock testing and real integration evidence](adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md)
- [Product identity and mailbox consent](adr/0061-separate-product-identity-from-registration-mailbox-authorization.md)
- [Originating-device Outbox and atomic admission](adr/0062-keep-queued-delivery-on-its-originating-device.md)
- [Private new-Inbox notifications](adr/0063-notify-for-new-inbox-mail-without-categorization.md)
- [Independent mobile and Mac dependency graphs](adr/0064-isolate-mobile-and-macos-native-dependencies.md)
- [Interview decisions and research](research/expo-react-native-rewrite.md)
- [Platform qualification and deferred native evidence](qualification/expo-react-native-client.md)
- [Complete ticket and dependency coverage](qualification/expo-rewrite-ticket-coverage.md)

## Shared policies

- [Root agent guide](../AGENTS.md) and [backend guide](../packages/convex/AGENTS.md)
- [Domain vocabulary](../CONTEXT.md) and [domain documentation policy](agents/domain.md)
- [Test admission, retirement, and feedback budgets](agents/testing.md)
- [GitHub issue workflow](agents/issue-tracker.md) and [triage labels](agents/triage-labels.md)
- [Automated reviews and PR babysitting](agents/pull-request-babysitting.md)
- [Code documentation patterns](../.patterns/README.md)

Preserve applicable privacy, encryption, identity-isolation, transport, and
delivery guarantees in the earlier [ADRs](adr/). ADR 0059 through 0064 take
precedence where they explicitly replace prototype architecture or release scope.
Earlier provider support, Profile features, Apple-only login, and cross-device
scheduled delivery are not implicit first-release requirements.

## Current Swift maintenance

These documents remain useful while the prototype is present. Their commands,
implementation details, and qualification results do not transfer to new hosts.

- [Swift setup and current behavior](swift-client.md)
- [Scoped Swift agent guide](../apps/unwired-mail/AGENTS.md)
- [Apple validation and CI contract](agents/apple-validation.md)
- [Mail test environment](mail-test-environment.md)
- [Protected Gmail test tenant](gmail-provider-test-tenant.md)
- [Storage and Product Sync export](storage-and-product-sync-export.md)
- [SwiftMail engine](qualification/swiftmail-engine.md) and [provider qualification](qualification/swiftmail-provider.md)
- [Mixed-provider qualification](qualification/mixed-provider-unified-mailbox.md)
- [Mail Assistance qualification](qualification/mail-assistance.md)

## Historical documents

[The archive](archive/README.md) retains seven superseded bootstrap, redesign,
scheduling, and library-research documents. Their links remain usable inside
the repository, but their old implementation status and rollout plans are
historical. ADRs keep their stable filenames and receive scope or supersession
notes where needed.

Update affected documentation in each implementation slice. At
[cutover #627](https://github.com/unwired-dev/product/issues/627), remove the
remaining Swift-specific setup, guides, commands, and tests only after verified
replacements exist. Keep useful historical decisions and provider evidence
clearly scoped rather than presenting them as replacement qualification.
