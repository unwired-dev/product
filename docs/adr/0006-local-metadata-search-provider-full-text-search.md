# Local metadata search and provider full-text search

The client will support local search over message metadata, mailbox state, and product categories, while relying on mail providers for full-text body search in v1. This avoids building a backend-readable mail search index or a durable plaintext local body index, while still giving users full-text search through provider-native capabilities.
