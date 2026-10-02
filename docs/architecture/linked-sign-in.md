# Linked Sign-In: architecture notes

Reviewer-only companion to [docs/linked-sign-in.md](../linked-sign-in.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Identity boundaries

1. The host reauthenticates the current Product Sign-In interactively. The subject
   must match the saved one. Convex then requires a token issued within five minutes
   and the device's Trusted Device Credential. It issues a single-use link ticket
   for the requested provider. The ticket expires after five minutes. Only its
   SHA-256 digest is stored, and a newer request for that provider replaces it.
2. The host runs a fresh interactive session for the other provider, with no
   account hint. Neither the Gmail mailbox nor an Apple relay address selects that
   identity. Convex checks the token's issuer and recent issue time, the ticket's
   provider and expiry, and the same Trusted Device and credential. It then
   records the Linked Sign-In and consumes the ticket in one transaction.

Convex resolves a Linked
Sign-In to its account only through the stored issuer and subject.

## Interruption and concurrency

Before then Convex stores only the pending ticket,
which a newer request may supersede.

Convex mutations are serializable, so racing link attempts cannot both commit.

Reconnects send the device's saved Product Account ID.

`productAccount:connect` fails with
`SIGN_IN_NOT_LINKED`.
