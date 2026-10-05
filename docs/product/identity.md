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
- **Product Sign-In** admits only the device that creates the account's keys. Every later device, on every account, signs in as a **Pending Device**: it reaches the Product Account but not its Product Sync keys, account operations, push routing or **Mailbox Authorization**
- A **Pending Device** may only ask for approval, read its own request, receive the key ring sealed to it, prove the **Recovery Key**, confirm it stored the keys, sign out, and delete the **Product Account** after a recent interactive **Product Sign-In**
- An existing **Trusted Device** holding the account's newest key epoch approves a **Pending Device** with that device's **Enrollment Code**, or the **Recovery Key** unlocks it. The device becomes a **Trusted Device** at that epoch only when it confirms after storing the keys; an approval whose approving device was removed, or whose epoch a removal superseded, is void and the device stays pending
- An approval opens only on the requesting device for its current request; replayed, expired, declined, superseded, revoked or mismatched approvals are refused without replacing account keys
- While a **Device Revocation**'s key rotation is pending, only the replacement **Recovery Key** that it issued admits a **Pending Device**; the previous Recovery Key keeps working for already-trusted devices until rotation completes. A person who loses every **Trusted Device** and holds only the previous Recovery Key during that interval cannot regain access, and deleting the **Product Account** is the only path left
- A device installation has at most one **Pending Device** and a **Product Account** at most three; a **Pending Device** ends with its **Enrollment Code**, does not count toward the **Trusted Device** limit or a pending key rotation, and the **Trusted Device** limit is enforced at admission

## Sign-in and mailbox permission

- **Product Sign-In** identifies a **Product Account** without implying **Mailbox Authorization**

## Sensitive operations and device revocation

- **Device Revocation**, **Delete Product Account**, connection removal, authorization or reauthorization, server verification, and mailbox-role remapping require connectivity and cannot appear complete while offline; removing **Mailbox Authorization** locally remains available offline and deletes local Keychain credentials and cached mailbox data
- **Device Revocation** immediately blocks the revoked device from Product Account APIs and push routing
- Device Revocation preserves its durable block despite sign-out, reconnect or late unregister.
- Every **Trusted Device** whose client supports device credentials presents its device-only **Trusted Device Credential** to Product Account, Product Sync, and push-relay APIs; a Trusted Device ID alone is not authentication proof. Routine reconnects preserve a valid credential so concurrent in-flight requests remain authorized; a missing or stale credential is replaced.
- A revoked device's own installation identifier and **Trusted Device Credential** stay refused ("This device was removed"). Under a new identifier it is a **Pending Device** like any other: it never receives a rotation transition, a recovery envelope or a newer key epoch unless it is admitted. A removed device with a live **Product Sign-In** can delete the **Product Account**'s synchronized data but can read none of it.
- **Device Revocation** rotates Product Sync key material for the remaining **Trusted Devices**, preventing the revoked device from reading future synchronized changes
- A revoked device purges local product data and mailbox credentials when it next connects, but revocation cannot guarantee erasure of data already copied from an offline or compromised device
- Provider authorization must be revoked separately through the **Mail Provider** when its device-local credential may be compromised
