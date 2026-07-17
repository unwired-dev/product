# Model Outbox delivery as immutable attempts

Offline and transiently failed Outbox messages will retry automatically with bounded exponential backoff, while authentication, policy, invalid-recipient, and other permanent failures stop for user action. Pending and failed messages remain editable or cancellable, but editing creates a new immutable Outgoing Delivery Attempt instead of mutating an attempt already in flight. This accepts explicit delivery state and attempt history to prevent ambiguous retries and accidental duplicate sends.
