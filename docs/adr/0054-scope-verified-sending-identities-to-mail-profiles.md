# Scope verified Sending Identities to Mail Profiles

Sending Identities are non-secret From-address definitions owned by exactly one Mailbox Connection and therefore one Mail Profile. Their definitions, verification state, and Profile default synchronize through the existing end-to-end encrypted Product Sync boundary. Provider credentials remain device-local. Existing primary addresses migrate as provider-confirmed identities, with the legacy Default Sending Connection choosing the initial default.

Gmail discovers only accepted Send As addresses through its authenticated provider API. Other adapters expose their primary address and let the provider honestly accept or reject a manually entered alias at send time. A manual alias becomes eligible only after a device-local self-addressed send succeeds and the locally generated one-time code is entered; neither value is sent to the product backend.

The composer persists the selected identity in Draft and Outbox state and includes its address in the provider-native From field. Replies and forwards select the authorized identity found in the receiving headers. If that identity, its connection, or its authorization is unavailable, Send fails closed until the user makes an explicit active-Profile choice. This prevents cross-Profile leakage and silent sender substitution while preserving provider-specific rejection behavior.
