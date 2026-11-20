---
status: accepted
---

# Block explicit sender domains beside exact Blocked Senders

## Context

[ADR 0051, Enforce profile-scoped Blocked Senders on trusted devices](0051-enforce-profile-blocked-senders-on-trusted-devices.md)
matches a **Blocked Sender** by its exact normalized address, never by a display
name or domain. On 2 November 2026 the product owner approved
[#1691](https://github.com/unwired-dev/product/issues/1691), which lets a person
block a whole sender domain, and on 12 November approved its block sheet and
Settings frames: subdomains are included by default, the sender's own host is
offered alone, and contacts at the domain can be exempted.

## Decision

A **Blocked Domain** is a separate profile-scoped preference beside the Blocked
Senders, so ADR 0051's exact-address rule for a Blocked Sender stays. It holds one
normalized domain the person chose explicitly, whether it also matches every
subdomain, and the exact addresses at it that it lets through. A domain is matched
as sender addresses carry it: lowercase letter, digit and hyphen labels, with an
internationalized name in its ASCII (`xn--`) form. Nothing is inferred: no
organization, display name, alias or lookalike domain matches, and a subdomain
matches only when the person chose it.

Blocked Domains live in the same device document and the same sealed Private Sync
record per **Mail Profile** as the Blocked Senders, merged domain by domain with
the same last-writer-wins rule and unblock tombstones. A record without domains
keeps its earlier shape, and a device that predates Blocked Domains reads the
addresses alone. Enforcement is ADR 0051's: only new arrivals, no notification, a
recoverable move to Trash through the owning **Mailbox Connection**, device-local
receipts and nothing restored by unblocking. An arrival whose exact address is a
Blocked Sender counts for that Blocked Sender, not for a Blocked Domain.

## Consequences

The backend still sees only an opaque record identifier and ciphertext. Exempt
addresses are stored and synchronized inside that ciphertext, since enforcement
runs where Contacts may not be readable. A device that predates Blocked Domains
rewrites a Profile's record without its domains when it changes an address there;
devices that know Blocked Domains publish them again on their next pass.
Choosing which domain the sheet offers, reading Contacts at the domain and showing
lookalike domains with their real characters belong to the clients
([#1691](https://github.com/unwired-dev/product/issues/1691)).
