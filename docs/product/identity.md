# Identity and devices: behavior notes

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](../architecture/product/identity.md).

[Vocabulary](../domain/identity.md) · [Domain index](../../GLOSSARY.md)

Product Account identity and device trust apply to the replacement. Advanced
Profiles are follow-up work; Default Profile and the deployed Profile Record
Scope describe prototype migration behavior.

These observable requirements were separated from the former monolithic glossary
and its implementation notes. The reviewer owns the separate architecture companion
under the [implementation and review workflow](../agents/implementation-review.md).
“v1” and “first release” in these notes refer to their original feature scope.
They do not establish replacement launch requirements or proof that a feature is
implemented.

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
- Device Revocation preserves its durable block despite sign-out, reconnect or late unregister.
- Every request requires the Trusted Device Credential; a Trusted Device ID alone is not authentication proof. Routine reconnects preserve valid in-flight authorization.
- Existing Product Accounts cannot perform a new Device Revocation until operators complete their retained-device identifier migration. Already-tombstoned accounts remain fail-closed during migration; newly created accounts are complete immediately, and a completed migration cannot admit another retained-device identifier.
- **Device Revocation** rotates Product Sync key material for the remaining **Trusted Devices**, preventing the revoked device from reading future synchronized changes
- A revoked device purges local product data and mailbox credentials when it next connects, but revocation cannot guarantee erasure of data already copied from an offline or compromised device
- Provider authorization must be revoked separately through the **Mail Provider** when its device-local credential may be compromised
