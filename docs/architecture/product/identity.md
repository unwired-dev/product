# Identity: architecture notes

Reviewer-only companion to [docs/product/identity.md](../../product/identity.md).
Read under the [implementation and review workflow](../../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Scope

Product Account identity and device trust apply to the replacement. Advanced
Profiles are follow-up work; Default Profile and the deployed Profile Record
Scope describe prototype migration behavior.

## Decisions and scope

- [Accepted replacement scope](../../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
- [Separate product identity from registration mailbox authorization](../../adr/0061-separate-product-identity-from-registration-mailbox-authorization.md)
- [Linked Google and Apple sign-in](../../linked-sign-in.md) for the replacement's explicit linking behavior
- [Separate encrypted Mail Profile ownership from legacy records](../../adr/0048-separate-encrypted-mail-profile-ownership.md)
- [Scope each window to one Mail Profile](../../adr/0050-scope-each-window-to-one-mail-profile.md)

[The documentation index](../../README.md) explains ADR precedence and separates
current replacement work from prototype maintenance and historical plans.

## Accounts and Profiles

- A Profile-scoped query requires an explicit **Mail Profile**

## Sensitive operations and device revocation

- For owner revocation, the Apple client retains and submits the selected Trusted Device ID, while Convex retains and resolves its account-scoped revocation target after sign-out; unregistering, reconnecting, or a late unregister cannot preserve live access or remove the durable identifier tombstone

- Every **Trusted Device** whose client supports device credentials presents its device-only **Trusted Device Credential** to Product Account, Product Sync, and push-relay APIs; routine reconnects preserve a valid credential so concurrent in-flight requests remain authorized, while a missing or stale credential is replaced; a Trusted Device ID alone is not authentication proof, and legacy devices reconnect after account-wide credential enforcement activates only when their exact pre-enforcement installation identifier was imported before the Product Account's migration marker was completed

- Existing Product Accounts cannot perform a new **Device Revocation** until deployment operators import the retained pre-enforcement Trusted Device inventory and complete that Product Account's identifier migration; already-tombstoned accounts remain fail-closed during migration, newly created accounts are complete immediately, and a completed migration cannot admit another identifier
