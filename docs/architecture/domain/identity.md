# Identity: architecture notes

Reviewer-only companion to [docs/domain/identity.md](../../domain/identity.md).
Read under the [implementation and review workflow](../../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Profile Record Scope

The **Default Profile** retains the deployed Product Account-scoped record identifiers; a new Profile receives a distinct opaque namespace.

## Trusted Device Credential

The Trusted Device Credential digest, not the credential, is stored by the backend.
