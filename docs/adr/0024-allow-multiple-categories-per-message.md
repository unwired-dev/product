# Allow multiple Categories per message

A message may belong to multiple Categories so one classification can appear in several Category-backed Mail Views and users can edit membership through a message-level multiselect control. System Categorization may assign every confidently matching purpose Category while People remains a fallback; user additions and removals create positive and negative future-only learning signals. Concurrent membership changes merge per Category, with user actions beating system actions and concurrent user removal beating addition. After that merge, the client removes only system-generated People membership whenever any purpose-specific system membership remains; an explicit user-added People membership is retained. Legacy single-category records migrate idempotently to compatible one-member sets in a new Product Sync namespace. Activating that namespace requires a synchronized minimum-client generation: old clients reject it and stop category writes, while updated clients retain legacy records until every trusted device acknowledges the generation or is revoked; only then may they retire legacy records. This fence prevents a mixed-version client from decoding or overwriting a multi-category set as one scalar assignment.

The collection implementation keeps the deployed `system:invoices` and `system:promotions`
identifiers so synchronized assignments and preferences remain stable while their display names become
Orders and Newsletters & Promotions. Multi-membership assignments, per-Category learning signals,
and Custom Category definitions use separate versioned Product Sync namespaces. Legacy assignment
payloads decode as one-member sets, and the legacy single Custom Category receives a default symbol
and color before being dual-written into the collection namespace. Classification remains
device-local, and every assignment, learning signal, and Custom Category value remains inside an
end-to-end encrypted payload. Assignment identifiers expose only a SHA-256 digest of the stable
provider message identity, learning-signal identifiers expose only an HMAC of the Category-and-sender
identity, and Custom Category identifiers expose the Category ID in reversible base64url form. The
Apple Product Sync client owns enforcement of the minimum-client generation fence and legacy
dual-write lifecycle; the TypeScript backend stores and compares only opaque encrypted records and
generation acknowledgements.
