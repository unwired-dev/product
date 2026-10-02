# Providers and mailboxes: behavior notes

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](../architecture/product/mailboxes.md).

[Vocabulary](../domain/mailboxes.md) · [Domain index](../../GLOSSARY.md)

The replacement launches with Gmail. The engine dependency, certified
Standards-Based Mail and legacy-provider terms describe the Swift prototype or
future work; they do not establish support in the new client.

These observable requirements were separated from the former monolithic glossary
and its implementation notes. The reviewer owns the separate architecture companion
under the [implementation and review workflow](../agents/implementation-review.md).
“v1” and “first release” in these notes refer to their original feature scope.
They do not establish replacement launch requirements or proof that a feature is
implemented.

## Client and provider boundary

- A **True email client** is responsible for mailbox access and message organization
- A **True email client** connects to one or more **Mail Providers**

## Connection identity and authorization

- A **Mailbox Connection** links one **Product Account** to one provider mailbox account supplied by a **Mail Provider** and contains that account's **Provider Mailboxes**
- A **Product Account** may contain only one **Mailbox Connection** for a **Stable Provider Connection Key**
- Re-adding an existing provider mailbox authorizes or repairs its **Mailbox Connection** instead of creating a duplicate. Concurrent additions converge without losing local credentials, cached mail or queued work.
- A **Mailbox Connection** definition, including its reviewed non-secret address, username, and endpoint settings, synchronizes end-to-end encrypted across trusted devices without provider credentials
- Each trusted device needs its own **Mailbox Authorization** before it can access a synchronized **Mailbox Connection**
- **Mailbox Authorization** prefers provider OAuth but may use a password or app-specific password over **Secure Mail Transport**
- Passwords, app-specific passwords, and OAuth refresh tokens remain in the current device's Keychain
- **Remove Device Authorization** affects only the current device and preserves the synchronized **Mailbox Connection**
- **Remove Mailbox Connection Everywhere** removes synchronized connection and product-owned state from all trusted devices but never deletes provider mail
- A trusted device that receives **Remove Mailbox Connection Everywhere** purges its **Mailbox Authorization** and cached mail for that connection before any later provider access or synchronization
- Recreating a removed **Mailbox Connection** with the same **Stable Provider Mailbox Identity** requires reauthorization on devices whose credentials predate its removal.
- After wake or reconnect, a trusted device applies synchronized connection removals before it resumes any queued **Provider Mail Action** or **Outgoing Delivery Attempt** for that connection

## Provider capabilities and engine boundary

- A **Standards-Based Mailbox Connection** requires both IMAP and SMTP before it is considered complete

- Gmail, **Standards-Based Mailbox Connections**, Microsoft Graph, and **On-Premises Exchange Connections** are **Full-Capability Mailbox Connections** only when every **Mailbox Role** required by their supported actions is mapped or successfully created; otherwise they remain incomplete for actions requiring a missing role
- A **Standards-Based Mailbox Connection** always supports provider read-state and star changes, exposes move-family actions only after verifying `MOVE` or `UIDPLUS`, and exposes role-targeting actions only when the required **Mailbox Role** has a trustworthy mapping
- A **Standards-Based Mailbox Connection** supports move, archive, and trash actions only when its server offers `MOVE` or `UIDPLUS` for targeted removal and returns a verified source-to-destination UID mapping such as `COPYUID`; it never uses an unrestricted expunge fallback that could remove unrelated messages

- A **Full-Capability Mailbox Connection** supports read state, archive, move, delete and restore, spam state, compose, reply, reply all, forward, product-owned drafts, and Outbox recovery

## Transport and legacy provider support

- IMAP, SMTP, POP3, and Exchange Web Services require **Secure Mail Transport**
- **Secure Mail Transport** prefers implicit TLS, permits STARTTLS only before authentication, and has no invalid-certificate override
- **Mailbox Service Discovery** happens on the device and never uploads an email address or server configuration to the product backend
- A user reviews discovered endpoints before connection and may enter host, port, username, and security settings manually when discovery fails
- Exchange Online and Microsoft 365 use Microsoft Graph, while an **On-Premises Exchange Connection** uses Exchange Web Services
- A **Legacy POP3 Connection** leaves downloaded messages on the server by default
- A **Legacy POP3 Connection** does not promise server-synchronized folders, moves, flags, or real-time delivery
- A **Legacy POP3 Connection** does not support server-side body search; it may search locally retained metadata, while body search remains unavailable unless the matching body is already available in the **Bounded Encrypted Body Cache**

## Unified mailboxes

- A **Unified Mailbox** aggregates a corresponding **Mailbox Role** or product-owned aggregate view across all **Mailbox Connections**
- The permanent **Unified Mailboxes** are Inbox, Snoozed, Pins, Drafts, **Sent Mailbox**, Archive, All Mail, Spam, and Trash

## All Mail

- **All Mail** is a product-local aggregate of every non-Spam, non-Trash message across all **Mailbox Connections**, not a required provider mailbox role

## Provider mailbox roles and navigation

- Provider-specific custom folders and labels remain under their **Mailbox Connection** and do not gain synthetic unified views
- Moving a Gmail message from a provider-specific label records and removes that selected source label while preserving every unrelated label
- Provider-native semantics or IMAP special-use markers assign a **Mailbox Role** when they are unambiguous
- A user explicitly maps any required **Mailbox Role** that a provider-synchronized connection does not identify unambiguously; if no provider mailbox can supply a required role, the client offers to create one when the provider permits it, otherwise the connection remains incomplete for actions requiring that role and has no product-local fallback. A **Legacy POP3 Connection** instead uses product-owned local roles for its reduced organization contract.
- **Mailbox Roles** are never inferred from localized folder names and user mappings may be changed later
- Changing a **Mailbox Role** mapping reclassifies existing local metadata and applies to future synchronization; the prior mapping is retained until the new mapping completes and may be restored if the change fails
- When a **Mailbox Role** mapping changes, every pending **Provider Mail Action** whose target or meaning changed is cancelled until the user reconfirms it against the new mapping
- A user may select either a **Unified Mailbox** or a mailbox within one **Mailbox Connection** to scope the messages being viewed

## Unified list behavior

- A **Unified Mailbox** interleaves mailbox-scoped **Threads** by latest message time rather than grouping them by account
- Every thread in a **Unified Mailbox** visibly identifies its source **Mailbox Connection**
- Background synchronization preserves the selected **Thread** when newer threads enter the list
- The unified **Sent Mailbox** is always available

## Pending provider actions

- A **True email client** supports **Provider Mail Actions**
- An offline **Provider Mail Action** becomes a **Pending Provider Action** and updates local presentation optimistically
- **Pending Provider Actions** are ordered per **Mailbox Connection** and retried when connectivity returns
- A permanently rejected **Pending Provider Action** restores provider-derived state, replays later pending actions in order, and produces a visible failure without overwriting newer optimistic changes
- An ambiguous provider response is reconciled before retrying a **Pending Provider Action** so the provider mutation is not duplicated
- For an ambiguous IMAP move, archive, or copy, the client retries only after it verifies the source-to-target mapping; otherwise it stops the action for user resolution rather than replaying it

## Bulk actions and provider rollout

- A bulk selection may span multiple **Mailbox Connections** but exposes only actions supported by every selected connection
- Bulk actions preserve per-connection ordering behind existing pending actions. Different connections progress independently, and successful batches remain successful when another connection fails.
- **Gmail-first provider support** limits the first release to Gmail **Mailbox Connections**, with IMAP/SMTP and Microsoft 365 planned afterward
