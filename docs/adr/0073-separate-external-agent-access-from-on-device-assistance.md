---
status: accepted
---

# Separate External Agent access from On-Device Mail Assistance

## Context

On 2026-10-19 the product owner confirmed the privacy and access boundaries
below during the [Agent access interview](../product/agent-access.md).
The interview and complete feature contract are confirmed. This record does not
approve runtime implementation or provide implementation or qualification
evidence. Agent access is a separate post-launch milestone under those
requirements.

## Decision

Allow users to authorize [External Agents](../domain/agent-access.md), such as
Codex and Claude, to access connected mail through Unwired. Require a separate,
explicit Agent Connection opt-in that discloses that retrieved mail may be
processed by the external agent or its model provider.

This consent qualifies the product's general on-device AI privacy promise for
External Agent access only. Built-in
[On-Device Mail Assistance](../domain/assistance.md) retains its no-cloud-fallback
contract and its existing input boundaries under
[ADR 0052](0052-keep-mail-assistance-on-device-and-input-bound.md).
Mail Assistance Enablement does not authorize an Agent Connection.

The first version serves External Agents through Unwired running on the user's
Mac. Agent access is unavailable when that Mac is unavailable. This decision
does not authorize new backend-readable mail or provider credentials, preserving
the backend privacy boundary in
[ADR 0002](0002-device-held-mail-provider-tokens-with-push-relay.md).

Restrict each Agent Connection to one [Mail Profile](../domain/identity.md) and
explicitly selected [Mailbox Connections](../domain/mailboxes.md). An Agent
Connection does not implicitly expose another Profile or an unselected connection.

The first version permits provider-mail search, fetching missing message bodies,
reading Threads, and creating or editing Drafts within that scope. It may expose
attachment names and basic metadata, but not attachment contents. Sending and
mailbox organization remain actions the user performs in Unwired. Future
Settings-configurable sending, deletion, and other actions require their own
permission and execution contracts.

## Consequences and implementation scope

External Agent access has an explicit external-processing privacy boundary
separate from built-in On-Device Mail Assistance. The first version depends
on the user's Mac and cannot promise access while that Mac is unavailable.

The [confirmed requirements](../product/agent-access.md) own the MCP helper,
connection approval and lifecycle, permissions, activity history, Draft safety,
and failure contracts. Keep those observable requirements there rather than
duplicating them in this decision. Concrete implementation mechanisms and
qualification remain work for the linked delivery tickets. Future sending,
deletion, and organization contracts remain outside the initial milestone.
