# Device-held mail provider tokens with push relay

The product needs push and sync behavior but should keep mail provider OAuth tokens on trusted user devices for v1. The backend may receive minimal mailbox-change metadata from provider push systems and route wakeups to devices through APNs, but it must not fetch mail, hold provider tokens, read message bodies, read categories, or perform classification. This preserves the privacy boundary while accepting more complex client-side sync, watch renewal, and background execution constraints.

For Gmail connection, trusted devices persist provider OAuth credentials locally and register only Operational Account Data with the backend: provider name, Gmail account identifier, email address, trusted device, and connection verification timestamps. Backend APIs for Gmail connection status must not accept or return access tokens, refresh tokens, message bodies, categories, or classification data.
