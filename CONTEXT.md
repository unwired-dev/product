# Private Email

This product helps people manage email without sending message content to a
server for AI processing. Its vocabulary belongs to one domain, organized by
reading topic below.

Read the topic relevant to your task and follow its links to behavior notes and
ADRs. Definitions include the Swift prototype, accepted replacement and future
work. A term's presence does not establish first-release scope or implementation;
use [the documentation index](docs/README.md) and
[ADR 0059](docs/adr/0059-replace-the-client-for-a-shared-cross-platform-product.md).

## Language

| Topic                                                   | Canonical vocabulary                                          | Behavior and decisions                                                                                                                               |
| ------------------------------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Accounts, Profiles, sign-in and trusted devices         | [Identity](docs/domain/identity.md)                           | [Identity notes](docs/product/identity.md)                                                                                                           |
| Providers, connections, authorization and mailbox roles | [Mailboxes](docs/domain/mailboxes.md)                         | [Mailbox notes](docs/product/mailboxes.md)                                                                                                           |
| Threads, drafts, sending identities and Outbox          | [Messages and delivery](docs/domain/messages-and-delivery.md) | [Delivery notes](docs/product/messages-and-delivery.md)                                                                                              |
| Categories, views, pins and cleanup                     | [Organization](docs/domain/organization.md)                   | [Organization notes](docs/product/organization.md)                                                                                                   |
| Encryption, storage, synchronization and notifications  | [Privacy and sync](docs/domain/privacy-and-sync.md)           | [Privacy and sync notes](docs/product/privacy-and-sync.md)                                                                                           |
| Compose, response, understanding and translation        | [Assistance](docs/domain/assistance.md)                       | [Assistance notes](docs/product/assistance.md)                                                                                                       |
| Mock sessions, scenarios, harnesses and evidence        | [Testing](docs/domain/testing.md)                             | [Testing policy](docs/agents/testing.md), [mock and integration evidence](docs/adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md) |

## Relationships

Behavior notes are grouped by topic in the table above. They preserve the former
relationship rules, including prototype constraints; each page links to the ADRs
that establish or supersede those rules. Read those sources before implementing
a rule that mentions v1, first release, migration or platform-specific behavior.

## Example dialogue

The earlier interview examples are preserved in
[historical domain discussions](docs/archive/domain-discussions.md#example-dialogue).

## Flagged ambiguities

The earlier resolutions are preserved in
[historical domain discussions](docs/archive/domain-discussions.md#flagged-ambiguities).
New unresolved questions belong in the relevant issue or design discussion.

## Maintaining this index

Follow the [domain documentation policy](docs/agents/domain.md) when adding,
renaming or moving terms. Keep each definition in one topic glossary, put behavior
in feature documentation or ADRs, and keep this file as the reading index.
