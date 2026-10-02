# Providers and mailboxes

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](../architecture/domain/mailboxes.md).

[Domain index](../../GLOSSARY.md) · [behavior notes](../product/mailboxes.md)

The replacement launches with Gmail. The engine dependency, certified
Standards-Based Mail and legacy-provider terms describe the Swift prototype or
future work; they do not establish support in the new client.

Each term has one canonical definition in this glossary collection. Use the
[documentation index](../README.md) and
[ADR 0059](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
for launch scope; a term's presence does not establish implementation or release.

## Language

**Private email client**:
An email client that connects to mail providers from trusted devices and keeps privacy-sensitive processing on those devices.
_Avoid_: Webmail, Apple Mail extension

**True email client**:
An email client that connects to mail providers directly and owns mailbox access, sync state, and message organization inside the product.
_Avoid_: Email assistant, Apple Mail extension

**Provider Mail Action**:
A user action that changes mailbox state through a mail provider's native capabilities.
_Avoid_: Product category action

**Pending Provider Action**:
A durable user-requested **Provider Mail Action** that has changed local presentation but still awaits provider confirmation.
_Avoid_: Outbox message, completed provider action

**Mail Provider**:
A service or protocol endpoint that supplies mailbox data to the product.
_Avoid_: Email backend, email source

**Approved Mail Engine Dependency**:
An exact-pinned third-party IMAP/SMTP engine admitted behind the product-owned Mail Engine boundary after deterministic qualification. Dependency approval does not certify any external Mail Provider or enable Standards-Based Mailbox Connections in an externally distributed release.
_Avoid_: Certified provider, universally compatible mail engine

**Standards-Based Mail**:
The IMAP/SMTP capability backed by the **Approved Mail Engine Dependency**. Its current exact pin is
available in external Release builds after passing iCloud Mail and Fastmail provider certification.
_Avoid_: Experimental dependency, universally certified provider support

**Mailbox Connection**:
An authenticated link between a **Product Account** and one provider mailbox account supplied by a **Mail Provider**; it may contain provider mailboxes such as folders or labels.
_Avoid_: Account, Product Account, provider account

**Provider Mailbox**:
A provider-owned folder, label, or equivalent mailbox container within one **Mailbox Connection** that may receive a **Mailbox Role**.
_Avoid_: Mailbox Connection, Unified Mailbox

**Stable Provider Mailbox Identity**:
A provider-issued immutable mailbox or account identifier; when a provider supplies none, the client uses its provider type, verified endpoint, and canonical authenticated mailbox identity and asks the user to repair rather than merge a mismatch.
_Avoid_: Display name, local database ID

**Stable Provider Connection Key**:
A deterministic, device-generated opaque key stored only inside the end-to-end encrypted **Mailbox Connection** definition. Trusted devices use it to converge concurrent additions of the same provider mailbox.
_Avoid_: Backend-readable email address, random local connection ID

**Mailbox Authorization**:
A device-local credential grant that lets one trusted device access a **Mailbox Connection**.
_Avoid_: Mailbox Connection, synced provider credential

**Remove Device Authorization**:
A device-scoped action that deletes local mailbox credentials and cached mail without removing the synchronized **Mailbox Connection**.
_Avoid_: Remove Mailbox Connection Everywhere

**Remove Mailbox Connection Everywhere**:
A product-account-scoped action that removes a **Mailbox Connection** and its product-owned state from every trusted device without deleting provider mail.
_Avoid_: Remove Device Authorization, delete provider mailbox

**Standards-Based Mailbox Connection**:
A **Mailbox Connection** that uses IMAP for mailbox access and synchronization and SMTP for outgoing mail delivery.
_Avoid_: IMAP-only account, read-only mailbox connection

**Full-Capability Mailbox Connection**:
A **Mailbox Connection** that provides the product's complete reading, organization, drafting, sending, and recovery action set.
_Avoid_: Legacy POP3 Connection, receive-only connection

**Secure Mail Transport**:
Encrypted provider communication using TLS 1.2 or newer with valid server identity before any mailbox authentication occurs.
_Avoid_: Plaintext mail access, invalid-certificate exception

**Mailbox Service Discovery**:
Device-side discovery of provider endpoints through email-service DNS records or a bundled reviewed catalog, with user-reviewed manual configuration as fallback.
_Avoid_: Backend account discovery, silent server guessing

**On-Premises Exchange Connection**:
A **Mailbox Connection** to an organization-hosted Exchange server through Exchange Web Services.
_Avoid_: Exchange Online EWS connection, Microsoft 365 EWS connection

**Legacy POP3 Connection**:
A limited **Mailbox Connection** that retrieves from one POP3 maildrop, sends through SMTP, and keeps mailbox organization as product-owned state.
_Avoid_: Standards-Based Mailbox Connection, synchronized server mailbox

**Unified Mailbox**:
A product-owned view that aggregates messages with the same mailbox role across all of a user's **Mailbox Connections**.
_Avoid_: Unified folder, mailbox account

**Mailbox Role**:
A provider-independent meaning such as Inbox, Sent, Drafts, Spam, Trash, or Archive assigned to a provider mailbox or label.
_Avoid_: Folder name, localized-name inference

**All Mail**:
A product-local aggregate of every message except Spam and Trash across all **Mailbox Connections**, available even when a provider has no native all-mail mailbox.
_Avoid_: Required provider folder, Gmail-only mailbox

**Sent Mailbox**:
A mailbox containing messages whose delivery has completed successfully; its unified form aggregates sent messages across **Mailbox Connections**.
_Avoid_: Outbox, sending queue

**Gmail-first provider support**:
The provider strategy where the first release supports only Gmail **Mailbox Connections**, with IMAP/SMTP and Microsoft 365 planned afterward.
_Avoid_: Provider-agnostic v1
