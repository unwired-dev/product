# Storage and Product Sync export

Privacy & Data > Storage & Export gives a signed-in person one place to inspect local mail storage, remove downloadable copies, and export Product Sync data.

## Device storage

The screen reports these device-local categories:

- durable provider message metadata;
- cached message bodies;
- complete encrypted Draft documents and Draft Assets;
- downloaded incoming attachments.

Draft storage has a device-wide 100 MB limit and is not evicted automatically. When synchronized Draft Asset content is not yet available locally, the screen reports the pending asset count and size. Clearing cached bodies and attachments preserves provider mail, metadata, Message Categories, Thread Pins, Draft documents, Draft Assets, and Product Sync records.

## Product Sync export

Export is available only from a Trusted Device with the Product Sync key material already present. The client paginates every encrypted Product Sync record, decrypts each payload on device with its record identifier as authenticated associated data, and writes readable, sorted JSON. It fails without producing a partial file when key material is missing, pagination is incomplete, a duplicate record is returned, decryption fails, or the export is cancelled.

The export contains the Product Account identifier, export time, format version, record identifiers and timestamps, and each decoded Product Sync value. This includes Mail Profile identity and ownership, multi-Category membership, Thread Pins, semantic Draft documents, and Draft Asset metadata and content. Provider credentials, Product Account identity tokens, and Trusted Device credentials are not Product Sync records and are excluded.

Product Sync ciphertext remains opaque to the backend. Plaintext export data exists only on the Trusted Device and in the location the person chooses through the system file exporter. Message content is not sent to the product backend for AI processing.

Recovery Key management remains under Account & Devices. Read Receipt behavior remains under Reading; Storage & Export summarizes the current incoming and outgoing policies and links there for changes.
