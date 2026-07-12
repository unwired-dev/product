# Classification engine interface

The Apple client will place email categorization behind a local Classification Engine interface rather than binding product logic directly to one Apple on-device AI API. Apple on-device AI is the preferred implementation, but the interface allows rule-based, platform-version-specific, or local model fallbacks while preserving the same output contract and keeping category immutability outside the classifier.

The first implementation is a deterministic local rule-based engine. Gmail metadata sync sends subject, snippet, and selected headers as Minimized Classification Input. The engine explicitly requests body text when metadata is insufficient; only then may the categorization service read an existing entry from the encrypted On-Demand Body Cache. Categorization never fetches a missing body from Gmail, and classification failures leave the message in Uncategorized State. Historical and already categorized messages bypass the engine.

Assigned Message Categories are encrypted on device and written to Product Sync using an opaque payload identifier derived from Stable Provider Message Identity. A synced assignment is loaded before local classification so another trusted device's existing assignment remains immutable.
