# Private Email

This context describes the language for an Apple-first private email product that helps people manage email without sending message content to a server for AI processing.

## Language

**Apple-first private email client**:
An email client for iOS, iPadOS, and macOS where privacy-sensitive processing is expected to happen on the user's device.
_Avoid_: Cross-platform email client, webmail

**True email client**:
An email client that connects to mail providers directly and owns mailbox access, sync state, and message organization inside the product.
_Avoid_: Email assistant, Apple Mail extension

**Provider Mail Action**:
A user action that changes mailbox state through a mail provider's native capabilities.
_Avoid_: Product category action

**Mail Provider**:
A service or protocol endpoint that supplies mailbox data to the product.
_Avoid_: Email backend, email source

**Gmail-first provider support**:
The initial provider strategy where Gmail is supported before generic IMAP and Microsoft mail.
_Avoid_: Provider-agnostic v1

**Category**:
A user-defined grouping used by the product to organize messages independently of provider folders and labels.
_Avoid_: Folder, Gmail label, Outlook category

**System Category**:
A product-provided **Category** available without user setup.
_Avoid_: Default folder, provider label

**Custom Category**:
A user-created **Category** for organizing messages according to the user's own needs.
_Avoid_: Custom folder, provider label

**Category Description**:
Optional user-written guidance that explains when a **Custom Category** should apply.
_Avoid_: Prompt, rule

**Message Category**:
A category assigned to an individual message, such as promotions, invites, invoices, or flights.
_Avoid_: Thread category, folder

**Stable Provider Message Identity**:
A provider-specific message identity used to match the same message across devices.
_Avoid_: Local database ID, backend message ID

**Uncategorized State**:
The state of a message when no **Message Category** has been assigned, including historical mail that is not automatically categorized.
_Avoid_: Uncategorized category, forced category

**Thread**:
A group of related messages shown together as a conversation.
_Avoid_: Category target

**System Categorization**:
Automatic assignment of a **Message Category** by the product.
_Avoid_: Manual category

**New-Mail-Only Categorization**:
The rule that **System Categorization** applies only to messages received after the app is installed for an account.
_Avoid_: Historical backfill

**Historical Categorization Opt-In**:
A user choice that allows old mail to be categorized during onboarding or later.
_Avoid_: Automatic historical backfill

**Bounded Historical Categorization**:
Historical categorization limited by user-selected scope such as date range, mailbox, label, or category target.
_Avoid_: All-mail backfill

**Minimized Classification Input**:
The least amount of message data needed for **System Categorization**, starting with metadata, subject, snippet, and headers before body text.
_Avoid_: Full-message classification by default

**Durable Message Metadata**:
Message-identifying and mailbox state data retained locally to support sync, display, and categorization without retaining full bodies by default.
_Avoid_: Full message archive

**On-Demand Body Cache**:
Locally retained message body content fetched or kept only as needed under retention controls.
_Avoid_: Permanent body store

**Minimal Push Metadata**:
The smallest mailbox-change data the backend may see to route sync wakeups to trusted devices.
_Avoid_: Server-side mailbox sync, backend mail access

**Category-Aware Notification**:
A notification shown only after local categorization determines the message matches the user's notification rules.
_Avoid_: Generic new-mail notification

**Notification Rule**:
User-owned preference that controls which categorized messages can produce visible notifications.
_Avoid_: Backend routing rule

**Generic Notification Fallback**:
An optional user setting that allows a visible new-mail notification when category-aware notification processing cannot finish in time.
_Avoid_: Default generic notification

**User Override**:
A category change made by the user after **System Categorization**.
_Avoid_: Recategorization

**Future Learning Signal**:
Information from a **User Override** that can improve categorization of future messages without changing already categorized messages.
_Avoid_: Retroactive recategorization

**Category Conflict Rule**:
The rule for resolving competing category assignments across trusted devices.
_Avoid_: Last-write-wins

**Synced Category**:
A **Category** that is available across the user's Apple devices without becoming provider-visible mailbox organization.
_Avoid_: Local-only category, provider label

**Product Account**:
An account owned by the product that identifies a user independently of their mail provider and Apple account.
_Avoid_: iCloud account, Gmail account, mailbox account

**Apple-First Sign-In**:
The Product Account sign-in strategy where Sign in with Apple is supported before email magic link.
_Avoid_: Password-first account

**Operational Account Data**:
Backend-readable account data needed to run identity, billing, device routing, and encrypted sync operations.
_Avoid_: User organization data, mailbox content

**Product Sync**:
Synchronization of product-owned user data across devices through the product's backend.
_Avoid_: iCloud sync, provider sync

**End-to-End Encrypted Product Sync**:
**Product Sync** where synced product data is readable only by the user's trusted devices.
_Avoid_: Server-readable sync, plaintext sync

**Recovery Key**:
A user-held secret that can restore access to encrypted product data when no trusted device is available.
_Avoid_: Password reset, support recovery

## Relationships

- An **Apple-first private email client** runs on iOS, iPadOS, and macOS
- A **True email client** is responsible for mailbox access and message organization
- A **True email client** connects to one or more **Mail Providers**
- A **True email client** supports **Provider Mail Actions**
- **Gmail-first provider support** means Gmail precedes generic IMAP and Microsoft mail
- A **Synced Category** belongs to the product, not to a **Mail Provider**
- A **Provider Mail Action** may change provider state, but a **Message Category** does not
- A **Product Account** identifies the user for **Product Sync**
- **Product Sync** shares **Synced Categories** across the user's devices
- **End-to-End Encrypted Product Sync** prevents the product backend from reading **Synced Categories**
- A **Recovery Key** can restore access to data protected by **End-to-End Encrypted Product Sync**
- A **Message Category** is assigned to an individual message, not to a **Thread**
- A **Message Category** syncs across devices by **Stable Provider Message Identity**
- A **Thread** groups related messages without being the categorization target
- **System Categorization** must not change an existing **Message Category**, whether it is a **System Category** or **Custom Category**
- A **User Override** may change an existing **Message Category**
- **New-Mail-Only Categorization** excludes historical mail from automatic categorization
- **Historical Categorization Opt-In** permits categorization of old mail when the user chooses it
- **Bounded Historical Categorization** limits **Historical Categorization Opt-In** to a user-selected scope
- A **Category** may be a **System Category** or a **Custom Category**
- A **Custom Category** may have a **Category Description**
- **System Categorization** uses **Minimized Classification Input** before inspecting message body text
- A message in **Uncategorized State** has no **Message Category**
- **System Categorization** may assign a **Message Category** to a message in **Uncategorized State**
- Historical mail remains in **Uncategorized State** under **New-Mail-Only Categorization**
- A **User Override** may become a **Future Learning Signal**
- A **Future Learning Signal** must not change existing **Message Categories**
- The **Category Conflict Rule** gives user actions priority over system actions and otherwise keeps the first assignment
- **Durable Message Metadata** is retained separately from the **On-Demand Body Cache**
- **System Categorization** may use the **On-Demand Body Cache** when **Minimized Classification Input** is insufficient
- **Minimal Push Metadata** may route a mailbox-change wakeup without exposing message bodies, provider tokens, categories, or classification data
- A **Category-Aware Notification** depends on local **System Categorization**
- A **Generic Notification Fallback** is optional and not the default notification behavior
- **Apple-First Sign-In** identifies a **Product Account**
- The backend may read **Operational Account Data** but not user organization data or mailbox content
- A **Notification Rule** is encrypted user data and is evaluated on trusted devices

## Example dialogue

> **Dev:** "Should the first version support Android?"
> **Domain expert:** "No — this is an **Apple-first private email client**, so iOS, iPadOS, and macOS come first."
> **Dev:** "Can we rely on Apple Mail as the source of messages?"
> **Domain expert:** "No — this is a **True email client**, so it connects to providers directly."
> **Dev:** "Can users archive, delete, reply, and use provider-native mailbox actions?"
> **Domain expert:** "Yes — a **True email client** supports **Provider Mail Actions**."
> **Dev:** "Should the provider layer be fully neutral from day one?"
> **Domain expert:** "No — use **Gmail-first provider support**, then add generic IMAP and Microsoft mail later."
> **Dev:** "When a message is put in a **Category**, should Gmail see that as a label?"
> **Domain expert:** "No — it should be a **Synced Category** that stays inside the product across Apple devices."
> **Dev:** "Can automatic categorization create Gmail labels or move IMAP folders in v1?"
> **Domain expert:** "No — **Message Categories** stay separate from **Provider Mail Actions** in v1."
> **Dev:** "Should category sync use iCloud?"
> **Domain expert:** "No — use a **Product Account** and **Product Sync**."
> **Dev:** "Can support inspect synced categories for debugging?"
> **Domain expert:** "No — **End-to-End Encrypted Product Sync** means only trusted user devices can read them."
> **Dev:** "Can a password reset recover encrypted categories?"
> **Domain expert:** "No — recovery requires a **Recovery Key** or an existing trusted device."
> **Dev:** "Should categorization apply to the whole conversation?"
> **Domain expert:** "No — assign a **Message Category** to each message, while the **Thread** only groups related messages."
> **Dev:** "How does a second device know which message an encrypted category assignment belongs to?"
> **Domain expert:** "Use **Stable Provider Message Identity** to match the same message across devices."
> **Dev:** "Can the system recategorize a message later?"
> **Domain expert:** "No — after **System Categorization**, only a **User Override** can change it."
> **Dev:** "Should old mail be categorized during account setup?"
> **Domain expert:** "No — use **New-Mail-Only Categorization** after the app is installed for the account."
> **Dev:** "Should historical mail have a separate not-processed state?"
> **Domain expert:** "No — historical mail remains in **Uncategorized State**."
> **Dev:** "Can the user choose to categorize old mail?"
> **Domain expert:** "Yes — offer **Historical Categorization Opt-In** during onboarding or later."
> **Dev:** "If the user opts in, should every historical message be categorized?"
> **Domain expert:** "No — use **Bounded Historical Categorization** so the user selects the scope."
> **Dev:** "Are all categories created by the user?"
> **Domain expert:** "No — use **System Categories** for common email types and **Custom Categories** for the user's own needs."
> **Dev:** "Is a custom category only a name?"
> **Domain expert:** "No — a **Custom Category** can include a **Category Description** to guide classification."
> **Dev:** "Can classification always inspect the full email body?"
> **Domain expert:** "No — start with **Minimized Classification Input** and inspect body text only when needed."
> **Dev:** "Should the classifier always pick the closest category?"
> **Domain expert:** "No — leave the message in **Uncategorized State** when confidence is too low."
> **Dev:** "Can user corrections improve future automatic categorization?"
> **Domain expert:** "Yes — a **User Override** can become a **Future Learning Signal**, but it must not recategorize existing messages."
> **Dev:** "If two devices categorize the same message before syncing, which assignment wins?"
> **Domain expert:** "Use the **Category Conflict Rule**: user action beats system action, otherwise first assignment wins."
> **Dev:** "Should the app permanently store every email body?"
> **Domain expert:** "No — store **Durable Message Metadata** and categorization, while using an **On-Demand Body Cache** with retention controls."
> **Dev:** "Can the backend participate in push without holding mail provider tokens?"
> **Domain expert:** "Yes — it may use **Minimal Push Metadata** to wake trusted devices, but devices fetch mail themselves."
> **Dev:** "Should users get generic new-mail alerts?"
> **Domain expert:** "No — prefer **Category-Aware Notifications** based on local categorization and user notification rules."
> **Dev:** "If category-aware processing cannot finish in the background, should the app still show a new-mail alert?"
> **Domain expert:** "No by default — only show one when the user enables **Generic Notification Fallback**."
> **Dev:** "Should account sign-in start with passwords?"
> **Domain expert:** "No — use **Apple-First Sign-In**, then add email magic link later if needed."
> **Dev:** "Can the backend read category names for support?"
> **Domain expert:** "No — the backend may only read **Operational Account Data**."
> **Dev:** "Can the backend read notification preferences to optimize routing?"
> **Domain expert:** "No — a **Notification Rule** is encrypted user data and devices decide whether to show notifications."

## Flagged ambiguities

- "email app" was resolved as **Apple-first private email client**, not a cross-platform email client.
- "email app" was resolved as **True email client**, not an assistant layer on top of Apple Mail.
- "main actions" was resolved as **Provider Mail Actions**, not product category actions.
- "category" was resolved as **Synced Category**, not a provider folder or label.
- "category-provider mapping" was resolved as separate in v1, not provider-visible category sync.
- "synced across devices" was resolved as **Product Sync**, not iCloud sync.
- "privacy-focused backend sync" was resolved as **End-to-End Encrypted Product Sync**, not server-readable sync.
- "recovery mechanism" was resolved as **Recovery Key**, not password-only recovery or support-assisted decryption.
- "categorization" was resolved as **Message Category** assignment, not thread-level categorization.
- "category sync identity" was resolved as **Stable Provider Message Identity**, not local database IDs.
- "cannot be changed by the system" was resolved as **System Categorization** being immutable unless changed by a **User Override**.
- "historical categorization" was resolved as **New-Mail-Only Categorization** by default with optional **Historical Categorization Opt-In**.
- "categorize old emails" was resolved as **Bounded Historical Categorization**, not all-mail backfill.
- "custom categories" was resolved as coexistence of **System Categories** and **Custom Categories**.
- "custom category definition" was resolved as a name plus optional **Category Description**.
- "AI input" was resolved as **Minimized Classification Input**, not full body text by default.
- "uncategorized" was resolved as **Uncategorized State**, not a category or separate historical-mail state.
- "learning from overrides" was resolved as **Future Learning Signal**, not retroactive recategorization.
- "category conflict resolution" was resolved as **Category Conflict Rule**, not last-write-wins.
- "email storage" was resolved as **Durable Message Metadata** plus **On-Demand Body Cache**, not permanent full-body storage.
- "push metadata" was resolved as **Minimal Push Metadata**, not server-side mailbox sync.
- "push notifications" was resolved as **Category-Aware Notifications**, not generic new-mail notifications.
- "notification fallback" was resolved as optional **Generic Notification Fallback**, not default behavior.
- "account sign-in" was resolved as **Apple-First Sign-In**, not password-first account creation.
- "backend-readable account data" was resolved as **Operational Account Data**, not user organization data or mailbox content.
- "notification rules" were resolved as encrypted user data, not backend-readable routing rules.
