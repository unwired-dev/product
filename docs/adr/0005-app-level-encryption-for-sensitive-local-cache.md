# App-level encryption for sensitive local cache

The Apple client will use normal SwiftData persistence for non-sensitive operational local state, but add an app-level encryption layer for sensitive body and cache stores. This keeps common model development simple while making cached message bodies, extracted text, and similarly sensitive local data explicitly protected beyond ordinary persistence defaults.
