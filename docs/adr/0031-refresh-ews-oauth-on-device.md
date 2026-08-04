---
status: accepted
---

# Refresh EWS OAuth authorization on device

Supported on-premises EWS deployments use OAuth 2.0 authorization code with PKCE through the system authentication session. The Apple target supplies the organization's HTTPS authorization endpoint, HTTPS token endpoint, public client identifier, callback scheme, and EWS scope. Unwired does not accept or bundle a client secret.

The access token, refresh token, and access-token expiry are one device-local authorization record in the ThisDeviceOnly Keychain. They never enter Product Sync or Convex. The synchronized EWS definition continues to contain only the reviewed endpoint, mailbox identity, username, authorization method, and server version. An older OAuth authorization record without refresh metadata fails closed as authorization-required instead of attempting provider access with an indefinitely stale token.

Every adapter path obtains authorization at the provider-access boundary. Tokens within five minutes of expiry are refreshed there, and concurrent callers for one mailbox share the same in-flight exchange. A successful exchange replaces the Keychain record, including a rotated refresh token, before the EWS request proceeds. An `invalid_grant` response clears the unusable authorization and requires the user to sign in again; transient transport and server failures preserve the refresh credential for a later retry.
