# Architecture index

This index and every file under `docs/architecture/` are reviewer-only under the
[implementation and review workflow](../agents/implementation-review.md).
Implementers use the [operational documentation index](../README.md), topic
vocabulary, observable requirements and coding conventions. The reviewer reads
the companions and relevant decisions, fixes validated issues and returns
operational outcomes without copying architecture into the implementer's context.
Architecture checking runs through the resolved repository OCR rules during that
handoff; [the coverage map](open-code-review.md) records rule ownership, source
authority and preserved review responsibilities.

The companions below contain extracted architecture and internal implementation
passages. Their source files retain setup, commands, validation and observable
behavior. The split preserves existing prototype, replacement, historical and
release scopes; a moved passage is not a new requirement or proof of qualification.

## Extracted companions

| Implementer-facing source                                                        | Reviewer-only companion                                                  |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| [README.md](../../README.md)                                                     | [repository.md](repository.md)                                           |
| [docs/agents/effect.md](../agents/effect.md)                                     | [agents/effect.md](agents/effect.md)                                     |
| [docs/apple-registration.md](../apple-registration.md)                           | [apple-registration.md](apple-registration.md)                           |
| [docs/account-removal.md](../account-removal.md)                                 | [account-removal.md](account-removal.md)                                 |
| [docs/domain/identity.md](../domain/identity.md)                                 | [domain/identity.md](domain/identity.md)                                 |
| [docs/domain/mailboxes.md](../domain/mailboxes.md)                               | [domain/mailboxes.md](domain/mailboxes.md)                               |
| [docs/domain/messages-and-delivery.md](../domain/messages-and-delivery.md)       | [domain/messages-and-delivery.md](domain/messages-and-delivery.md)       |
| [docs/domain/privacy-and-sync.md](../domain/privacy-and-sync.md)                 | [domain/privacy-and-sync.md](domain/privacy-and-sync.md)                 |
| [docs/expo-client.md](../expo-client.md)                                         | [expo-client.md](expo-client.md)                                         |
| [docs/gmail-inbox.md](../gmail-inbox.md)                                         | [gmail-inbox.md](gmail-inbox.md)                                         |
| [docs/google-registration.md](../google-registration.md)                         | [google-registration.md](google-registration.md)                         |
| [docs/linked-sign-in.md](../linked-sign-in.md)                                   | [linked-sign-in.md](linked-sign-in.md)                                   |
| [docs/macos-client.md](../macos-client.md)                                       | [macos-client.md](macos-client.md)                                       |
| [docs/mail-test-environment.md](../mail-test-environment.md)                     | [mail-test-environment.md](mail-test-environment.md)                     |
| [docs/mock-mail-sessions.md](../mock-mail-sessions.md)                           | [mock-mail-sessions.md](mock-mail-sessions.md)                           |
| [docs/private-inbox-storage.md](../private-inbox-storage.md)                     | [private-inbox-storage.md](private-inbox-storage.md)                     |
| [docs/private-product-sync.md](../private-product-sync.md)                       | [private-product-sync.md](private-product-sync.md)                       |
| [docs/product/assistance.md](../product/assistance.md)                           | [product/assistance.md](product/assistance.md)                           |
| [docs/product/identity.md](../product/identity.md)                               | [product/identity.md](product/identity.md)                               |
| [docs/product/mailboxes.md](../product/mailboxes.md)                             | [product/mailboxes.md](product/mailboxes.md)                             |
| [docs/product/messages-and-delivery.md](../product/messages-and-delivery.md)     | [product/messages-and-delivery.md](product/messages-and-delivery.md)     |
| [docs/product/organization.md](../product/organization.md)                       | [product/organization.md](product/organization.md)                       |
| [docs/product/privacy-and-sync.md](../product/privacy-and-sync.md)               | [product/privacy-and-sync.md](product/privacy-and-sync.md)               |
| [docs/storage-and-product-sync-export.md](../storage-and-product-sync-export.md) | [storage-and-product-sync-export.md](storage-and-product-sync-export.md) |
| [docs/swift-client.md](../swift-client.md)                                       | [swift-client.md](swift-client.md)                                       |

## Replacement decisions and evidence

- [Accepted product and platform scope](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
- [Mock testing and real integration evidence](../adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md)
- [Product identity and mailbox consent](../adr/0061-separate-product-identity-from-registration-mailbox-authorization.md)
- [Originating-device Outbox and atomic admission](../adr/0062-keep-queued-delivery-on-its-originating-device.md)
- [Private new-Inbox notifications](../adr/0063-notify-for-new-inbox-mail-without-categorization.md)
- [Workspace catalogs and native dependency boundaries](../adr/0064-isolate-mobile-and-macos-native-dependencies.md)
- [Effect adoption scope](../adr/0065-scope-effect-adoption.md)
- [Device admission through authorized enrollment](../adr/0066-admit-devices-only-through-authorized-enrollment.md)
- [Minimal native vault and TypeScript-owned client logic](../adr/0067-keep-native-code-to-a-minimal-vault.md)
- [Interview decisions and research](../research/expo-react-native-rewrite.md)
- [Platform qualification and deferred native evidence](../qualification/expo-react-native-client.md)
- [Complete ticket and dependency coverage](../qualification/expo-rewrite-ticket-coverage.md)

The resolved OCR checklist requires the review agent to check applicable privacy,
encryption, identity-isolation, transport and delivery guarantees in the earlier
[ADRs](../adr/). ADR 0059 through 0067 take
precedence where they explicitly replace prototype architecture or release scope.
Earlier provider support, Profile features, Apple-only login, and cross-device
scheduled delivery are not implicit first-release requirements.

## Existing reviewer-only sources

These directories remain whole reviewer-only sources; use their original filenames.

- [Architecture decision records](../adr/README.md): an index of every ADR, with duplicate numbers disambiguated; accepted replacement decisions and earlier privacy, identity, transport and delivery decisions.
- [Code documentation and architecture patterns](../../.patterns/README.md).
- [Technical research](../research/expo-react-native-rewrite.md).
- [Platform and provider qualification](../qualification/).
- [Historical archive index](../archive/README.md).

## Prototype qualification

- [SwiftMail engine](../qualification/swiftmail-engine.md) and [provider qualification](../qualification/swiftmail-provider.md)
- [Mixed-provider qualification](../qualification/mixed-provider-unified-mailbox.md)
- [Mail Assistance qualification](../qualification/mail-assistance.md)

## Historical documents

[The archive](../archive/README.md) retains superseded bootstrap, redesign,
scheduling and library-research documents, plus historical domain discussions.
Their links remain usable inside the repository, but their old implementation
status and rollout plans are historical. ADRs keep their stable filenames and
receive scope or supersession notes where needed.

Update affected documentation in each implementation slice. At
[cutover #627](https://github.com/unwired-dev/product/issues/627), remove the
remaining Swift implementation, build targets and tests after their replacement
slices are complete. Obsolete Swift operating instructions can be removed now.
Keep useful historical decisions and provider evidence clearly scoped rather
than presenting them as replacement qualification.
