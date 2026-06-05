# Classification engine interface

The Apple client will place email categorization behind a local Classification Engine interface rather than binding product logic directly to one Apple on-device AI API. Apple on-device AI is the preferred implementation, but the interface allows rule-based, platform-version-specific, or local model fallbacks while preserving the same output contract and keeping category immutability outside the classifier.
