# Messages and delivery: architecture notes

Architecture notes for [docs/domain/messages-and-delivery.md](../../domain/messages-and-delivery.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Stable Provider Message Identity

Gmail uses its immutable message resource ID; Microsoft Graph connections require immutable IDs; IMAP uses its immutable provider-mailbox identity plus UIDVALIDITY and UID; POP3 connections require UIDL; and Exchange uses its provider item identity.

Provider adapters retain a verified repair mapping for provider-issued identity changes such as moves; if repair is ambiguous or unavailable, they create a distinct product record rather than applying product state to the wrong message.

## Stable Thread Identity

Stable Thread Identity is derived from a reliable provider conversation identity or verified RFC reply linkage.
