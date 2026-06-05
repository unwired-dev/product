# End-to-end encrypted product sync

The product uses its own account system and backend to sync product-owned email organization data across a user's Apple devices. We will make this sync end-to-end encrypted so the backend can transport and store synced data, but cannot read synced categories or message-category assignments. This preserves the privacy promise while accepting additional complexity in trusted device enrollment, account recovery, support, and sync conflict handling.
