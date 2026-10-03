# Identity and devices

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](../architecture/domain/identity.md).

[Domain index](../../GLOSSARY.md) · [behavior notes](../product/identity.md)

Product Account identity and device trust apply to the replacement. Advanced
Profiles are follow-up work; Default Profile and the deployed Profile Record
Scope describe prototype migration behavior.

Each term has one canonical definition in this glossary collection. Use the
[documentation index](../README.md) and
[ADR 0059](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
for launch scope; a term's presence does not establish implementation or release.

## Language

**Delete Product Account**:
An immediate, irreversible action that deletes the user's product identity, operational data, encrypted Product Sync data, and push routes without deleting provider mail.
_Avoid_: Remove Mailbox Connection Everywhere, delete provider mailbox, recoverable deactivation

**Product Account**:
An account owned by the product that identifies a user independently of their mail provider and Apple account.
_Avoid_: iCloud account, Gmail account, mailbox account

**Mail Profile**:
An end-to-end encrypted workspace inside one **Product Account** that owns a disjoint set of **Mailbox Connections** and the product-owned organization, automation, sending identities, and **Mail Workflow Preferences** applied to those connections.
_Avoid_: Product Account, provider account, shared workspace

**Default Profile**:
The lossless migrated **Mail Profile** that owns every pre-Profile **Mailbox Connection** and existing product-owned record in place without copying, resetting, or exposing that state.
_Avoid_: Startup Profile, default mailbox account

**Startup Profile**:
The device-local **Mail Profile** used only when opening a new app window. A restored window keeps its own last active Profile, and a targeted deep link takes precedence over both restoration and Startup Profile.
_Avoid_: Default Profile, default sending account

**Mail Profile Window**:
One app window whose navigation, Unified Mailboxes, Mail Views, search, composer, and message context are constrained to exactly one active **Mail Profile** while background synchronization continues for every Profile.
_Avoid_: Product Account window, combined workspace

**Profile Record Scope**:
The opaque Product Sync namespace owned by one **Mail Profile**.
_Avoid_: provider namespace, device-local directory

**Product Sign-In**:
Authentication that establishes access to a **Product Account** through a supported **Sign-In Provider**, independently of permission to access a mailbox.
_Avoid_: Mailbox Authorization, Apple-First Sign-In

**Sign-In Provider**:
An identity service a person uses to authenticate to a **Product Account**. Its identity grant does not itself authorize access to mail from a **Mail Provider**.
_Avoid_: Mail Provider, Mailbox Connection

**Linked Sign-In**:
A verified association between one **Product Account** and an identity at a **Sign-In Provider**, allowing that identity to authenticate to the same Product Account.
_Avoid_: Mailbox Connection, matching email address, automatically linked mailbox identity

**Operational Account Data**:
Backend-readable account data needed to run identity, billing, device routing, and encrypted sync operations.
_Avoid_: User organization data, mailbox content

**Trusted Device**:
A user-approved device authorized to access one **Product Account** and participate in **End-to-End Encrypted Product Sync**.
_Avoid_: Mailbox Authorization, remembered login

**Enrollment Code**:
A one-time code shown on a device waiting for **End-to-End Encrypted Product Sync** keys. A person enters it on a **Trusted Device** to approve that device, and the backend never receives it.
_Avoid_: pairing code, verification code, PIN

**Trusted Device Credential**:
An unlisted device-only secret that proves a request comes from one **Trusted Device**.
_Avoid_: Trusted Device ID, Apple identity token

**Device Revocation**:
A Product Account action that blocks one former **Trusted Device** from account APIs, push routing, and future encrypted sync data.
_Avoid_: Guaranteed remote erase, provider-token revocation
