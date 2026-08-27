# Storage and Product Sync export

Privacy & Data > Storage & Export gives a signed-in person one place to inspect local mail storage, remove downloadable copies, and export Product Sync data.

## Device storage

The screen reports these device-local categories:

- durable provider message metadata;
- cached message bodies;
- complete encrypted Draft documents and Draft Assets;
- downloaded incoming attachments;
- encrypted authorized remote message content.

The non-evicting Outgoing Content Store has a device-wide 100 MB limit; Draft Assets are tracked separately. When synchronized Draft Asset content is not yet available locally, the screen reports the pending asset count and size. The Authorized Remote Content Cache has its own device-wide 250 MB least-recently-used limit and preserves content currently displayed in the reader. Its entries remain separated by Product Account, Mail Profile, Mailbox Connection, Stable Provider Message Identity, and resource revision.

Clearing cached bodies and attachments preserves provider mail, metadata, Product-owned Categories, Thread Pins, Draft documents, Draft Assets, Product Sync records, and authorized remote content. Clear Remote Content removes only the encrypted remote resources stored on the device; it does not delete provider mail. A later authorized presentation downloads missing resources again. Removing a Mail Profile removes its remote-content entries.

## Product Sync export

Export is available only from a Trusted Device with the Product Sync key material already present. The client paginates every exportable encrypted Product Sync record, excluding the Product Account recovery payload, decrypts each payload on device with its record identifier as authenticated associated data, and writes readable, sorted JSON. It fails without producing a partial file when key material is missing, pagination is incomplete, a duplicate record is returned, payload decoding or decryption fails, or the export is cancelled.

The export contains the Product Account identifier, export time, format version, record identifiers and timestamps, and each decoded Product Sync value. This includes Mail Profile identity and ownership, multi-Category membership, Thread Pins, semantic Draft documents, and available Draft Asset metadata and content. Provider credentials, Product Account session credentials, and Trusted Device credentials are not Product Sync records and are excluded.

Product Sync ciphertext remains opaque to the backend. Plaintext export data exists only on the Trusted Device and in the location the person chooses through the system file exporter. Message content is not sent to the product backend for AI processing.

Recovery Key management remains under Account & Devices. In Reading > Read Receipts, incoming requests ask every time and are never silently acknowledged, while outgoing requests are off by default. Storage & Export shows the current policies and links to that Reading destination for changes.
