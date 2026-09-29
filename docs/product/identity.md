# Identity and devices: behavior notes

[Vocabulary](../domain/identity.md) · [Domain index](../../CONTEXT.md)

Product Account identity and device trust apply to the replacement. Advanced
Profiles are follow-up work; Default Profile and the deployed Profile Record
Scope describe prototype migration behavior.

The notes below were moved from `CONTEXT.md` without changing their wording.
They mix retained product constraints with prototype implementation and feature
scope. Read them alongside the accepted ADRs; “v1” and “first release” in these
notes refer to their original feature scope. They do not establish replacement
launch requirements or proof that a feature is implemented.

## Decisions and scope

- [Accepted replacement scope](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
- [Separate product identity from registration mailbox authorization](../adr/0061-separate-product-identity-from-registration-mailbox-authorization.md)
- [Separate encrypted Mail Profile ownership from legacy records](../adr/0048-separate-encrypted-mail-profile-ownership.md)
- [Scope each window to one Mail Profile](../adr/0050-scope-each-window-to-one-mail-profile.md)

[The documentation index](../README.md) explains ADR precedence and separates
current replacement work from prototype maintenance and historical plans.

## Accounts and Profiles

- A **Product Account** may own multiple **Mailbox Connections**
- Every **Mailbox Connection** belongs to exactly one **Mail Profile**
- A newly drafted **Mail Profile** can be named and styled in device-local protected state while offline, retaining its opaque identity until encrypted Product Sync succeeds
- Duplicating a **Mail Profile** copies only the reviewed Profile-scoped configuration; it never copies Mailbox Connections, provider credentials, cached mail, Drafts, Outbox attempts, history, or connection-scoped pins
- Moving a **Mailbox Connection** between Profiles preserves its stable identity and device-local authorization, commits ownership and reviewed custom-Category copies atomically while online, and leaves source Profile-wide preferences in place
- A Profile-scoped query requires an explicit **Mail Profile**
- Every **Mail Profile Window** restores one device-local Profile; targeted deep links override restoration and the **Startup Profile**
- Provider credentials remain device-local and outside **Profile Record Scope**

## Account deletion

- **Delete Product Account** requires recent authentication and explicit confirmation, has no recovery grace period, and cannot be undone
- **Delete Product Account** removes backend operational account data, encrypted Product Sync payloads, and push routes and instructs reachable devices to purge local product data and mailbox credentials
- **Delete Product Account** never deletes provider mail and does not promise to revoke authorization already issued by a **Mail Provider**

## Account identity for Product Sync

- A **Product Account** identifies the user for **Product Sync**

## Sign-in and mailbox permission

- **Product Sign-In** identifies a **Product Account** without implying **Mailbox Authorization**

## Sensitive operations and device revocation

- **Device Revocation**, **Delete Product Account**, connection removal, authorization or reauthorization, server verification, and mailbox-role remapping require connectivity and cannot appear complete while offline; removing **Mailbox Authorization** locally remains available offline and deletes local Keychain credentials and cached mailbox data
- **Device Revocation** immediately blocks the revoked device from Product Account APIs and push routing
- For owner revocation, the Apple client retains and submits the selected Trusted Device ID, while Convex retains and resolves its account-scoped revocation target after sign-out; unregistering, reconnecting, or a late unregister cannot preserve live access or remove the durable identifier tombstone
- Every **Trusted Device** whose client supports device credentials presents its device-only **Trusted Device Credential** to Product Account, Product Sync, and push-relay APIs; routine reconnects preserve a valid credential so concurrent in-flight requests remain authorized, while a missing or stale credential is replaced; a Trusted Device ID alone is not authentication proof, and legacy devices reconnect after account-wide credential enforcement activates only when their exact pre-enforcement installation identifier was imported before the Product Account's migration marker was completed
- Existing Product Accounts cannot perform a new **Device Revocation** until deployment operators import the retained pre-enforcement Trusted Device inventory and complete that Product Account's identifier migration; already-tombstoned accounts remain fail-closed during migration, newly created accounts are complete immediately, and a completed migration cannot admit another identifier
- **Device Revocation** rotates Product Sync key material for the remaining **Trusted Devices**, preventing the revoked device from reading future synchronized changes
- A revoked device purges local product data and mailbox credentials when it next connects, but revocation cannot guarantee erasure of data already copied from an offline or compromised device
- Provider authorization must be revoked separately through the **Mail Provider** when its device-local credential may be compromised
