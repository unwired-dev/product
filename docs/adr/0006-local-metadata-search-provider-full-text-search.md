# Local metadata search and provider full-text search

## Automatic provider search amendment — 2026-11-11

[ADR 0077](0077-remove-friction-that-privacy-does-not-require.md) supersedes provider search only on an explicit request. When the device is
online a query also goes to the provider automatically, and its results are
labeled apart from the saved ones
([#847](https://github.com/unwired-dev/product/issues/847)). Offline body search,
visible coverage and the prohibition on backend-readable mail indexing remain in
force.

## Launch scope amendment — 2026-10-11

The power-user Apple launch adds offline search of downloaded bodies with visible
coverage and explicit online search for the remainder. This supersedes the
provider-only body-search launch scope below, preserving the prohibition on
backend-readable mail indexing. See
[ADR 0069](0069-expand-the-apple-launch-to-power-user-mail.md).

The client will support local search over message metadata, mailbox state, and product categories, while relying on mail providers for full-text body search in v1. This avoids building a backend-readable mail search index or a durable plaintext local body index, while still giving users full-text search through provider-native capabilities.
