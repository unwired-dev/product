# Messages and delivery

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](../architecture/domain/messages-and-delivery.md).

[Domain index](../../GLOSSARY.md) · [behavior notes](../product/messages-and-delivery.md)

The replacement keeps queued delivery on its originating device under
[ADR 0062](../adr/0062-keep-queued-delivery-on-its-originating-device.md).
Scheduled Send Claim and Scheduled Delivery Authorization name the older
cross-device scheduling protocol; their definitions do not authorize takeover
in the replacement.

Each term has one canonical definition in this glossary collection. Use the
[documentation index](../README.md) and
[ADR 0059](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
for launch scope; a term's presence does not establish implementation or release.

## Language

**Default Sending Connection**:
The legacy user-selected **Mailbox Connection** whose primary address migrates to the initial **Default Sending Identity**.
_Avoid_: Most recently used account, reply identity, current default after migration

**Sending Identity**:
A provider-authorized From address that belongs to exactly one **Mailbox Connection** and therefore one **Mail Profile**. Provider-confirmed addresses are immediately eligible; a manual alias becomes eligible only after a device-local self-addressed provider test and one-time code.
_Avoid_: Backend-readable alias, cross-Profile sender, unverified From address

**Default Sending Identity**:
The user-selected **Sending Identity** used by default for newly composed messages in one **Mail Profile**.
_Avoid_: Most recently used address, reply identity, Default Sending Connection

**Message Read State**:
The provider-visible read or unread state of a message within a **Mailbox Connection**.
_Avoid_: Read Receipt, local viewing history

**Read Receipt**:
An acknowledgement that may tell a sender their message was opened, kept separate from the message's **Message Read State**.
_Avoid_: Read status, unread indicator

**Outbox**:
A product-owned queue containing outgoing messages that are pending, retrying, or failed rather than confirmed as sent.
_Avoid_: Sent Mailbox, sent folder

**Draft**:
An editable, unsent outgoing message retained by the product until it is explicitly discarded or durably admitted to the **Outbox**. Selecting a product-authored Draft opens it directly for editing; it has no read-only presentation.
_Avoid_: Outbox message, temporary composer

**Semantic Message Document**:
The editable message-body representation shared by Markdown input shortcuts, formatting controls, context actions, Draft synchronization, and outgoing format generation.
_Avoid_: Stored Markdown, raw HTML draft

**Slash Command Menu**:
A command picker opened by typing `/` in the authored body. It filters semantic formatting commands and explicitly invoked **Compose Assistance** actions without storing slash syntax in the **Semantic Message Document** or starting generation automatically.
_Avoid_: Automatic generation, body autocomplete, stored slash command

**Mail Template**:
A reusable name, subject, and versioned **Semantic Message Document** synchronized end-to-end within one **Mail Profile**. Applying a Mail Template creates a new **Draft** or inserts its semantic body into an existing Draft without flattening formatting or silently replacing authored content.
_Avoid_: Canned recipient, auto-send rule, global template, Named Template, message template

**Outgoing Delivery Attempt**:
An immutable attempt to send one Outbox message through a selected **Mailbox Connection**.
_Avoid_: Draft edit, Provider Mail Action

**Delivery Owner**:
The trusted device where the person pressed Send and that owns execution of the resulting queued **Outgoing Delivery Attempt**.
_Avoid_: Current foreground device, backend mail sender, any available device

**Undo Send Window**:
A user-selected delay before an **Outgoing Delivery Attempt** is handed to its provider, during which the Outbox message remains cancellable.
_Avoid_: Provider recall, retract delivered message

**Scheduled Send**:
A one-time commitment to deliver an outgoing message at or after a user-selected future time.
_Avoid_: Delayed send, planned send, recurring send, Undo Send Window

**Send Reminder**:
A one-time future prompt attached to a **Draft** that does not authorize the product to deliver the message.
_Avoid_: Scheduled Send, automatic send

**Scheduled Send Claim**:
A revision-bound right held by one eligible **Trusted Device** to advance a **Scheduled Send** toward provider handoff.
_Avoid_: Unfenced timer, renewable delivery lease

**Scheduled Delivery Authorization**:
A revocable device-bound authorization that permits a compatible **Trusted Device** to claim and revalidate Scheduled Send delivery without interactive sign-in.
_Avoid_: Mailbox Authorization, provider credential, backend delivery credential

**Stable Provider Message Identity**:
A provider-specific message identity used to match the same message across devices. A provider that cannot supply the required stable identity is not eligible for a synchronized Mailbox Connection. Ambiguous or unavailable identity repair must not apply product state to the wrong message.
_Avoid_: Local database ID, backend message ID

**Thread**:
A group of related messages within one **Mailbox Connection**, shown together as a conversation.
_Avoid_: Category target

**Stable Thread Identity**:
A **Mailbox Connection**-scoped identity used to preserve product-owned Thread state across trusted devices.
_Avoid_: Subject, latest message identity

**Inline Image**:
An image placed at a position inside message content and delivered as a MIME part rather than fetched as **Remote Message Content**. A user-authored Inline Image occupies a position in the **Semantic Message Document**; a received Inline Image is resolved from its normalized Content-ID only when that message is explicitly opened.
_Avoid_: Image attachment, remote image

**Attachment**:
A file delivered with a received or outgoing message outside the ordered body content.
_Avoid_: Inline Image, Remote Message Content

**Downloaded Attachment**:
A device-local copy of a received **Attachment** retained after an explicit or policy-permitted download.
_Avoid_: Attachment, Draft Asset, synchronized attachment

**Draft Asset**:
The encrypted source bytes and metadata for an **Attachment** or **Inline Image** retained with a **Draft** before Outbox admission.
_Avoid_: Downloaded attachment, remote image

**Outgoing Content Store**:
The non-evicting encrypted 100 MB device-wide store shared by **Drafts**, **Send Reminders**, **Scheduled Sends**, and their authored semantic documents, attachments, inline images, and other message assets.
_Avoid_: Draft-only store, Bounded Encrypted Body Cache, provider Draft mailbox

**Share Intake Draft**:
A device-local encrypted Draft created by the Apple Share Extension from explicit text, links, images, or files. It is bound to one authenticated **Mail Profile** and **Sending Identity**, enters the normal Draft store when Unwired Mail opens, remains editable, and never authorizes delivery.
_Avoid_: direct share, shared message, automatic send

**Formatting Toolbar Preference**:
The global **Mail Workflow Preference** that controls whether the composer displays its formatting toolbar without disabling formatting capabilities.
_Avoid_: Plain-text mode, formatting disablement

**Recipient Suggestion**:
An on-device autocomplete candidate derived from recent local correspondence and permissioned Apple Contacts. Accepting one creates a validated recipient token and cannot duplicate an address already present in To, Cc, or Bcc.
_Avoid_: Backend contact, uploaded address query

**Raw Message Source**:
The exact provider-returned RFC 822 or MIME bytes for one message, fetched only after an explicit source-inspector action. The Apple client may parse those bytes into a separate header view, but Copy Source and `.eml` export preserve the original byte sequence; metadata-only fallback is labelled as non-exact and is never reconstructed into synthetic source.
_Avoid_: Reconstructed email, generated MIME source

**Attachment Preview**:
A device-local presentation of a **Downloaded Attachment** using a supported system preview rather than message-body rendering.
_Avoid_: Inline Image, Remote Message Content, attachment download
