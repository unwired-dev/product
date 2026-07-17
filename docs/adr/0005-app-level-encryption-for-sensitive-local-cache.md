---
status: superseded by ADR-0012
---

# App-level encryption for sensitive local cache

The Apple client will use normal SwiftData persistence for non-sensitive operational local state, but add an app-level encryption layer for sensitive body and cache stores. This keeps common model development simple while making cached message bodies, extracted text, and similarly sensitive local data explicitly protected beyond ordinary persistence defaults.

Gmail message bodies are fetched only when a user opens a message. The On-Demand Body Cache stores an authenticated encrypted payload keyed by the Stable Provider Message Identity, while Durable Message Metadata and Message Categories remain in their separate metadata store. Users can remove a cached body without affecting that metadata or category state.
