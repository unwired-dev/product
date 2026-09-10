---
status: accepted
---

# Separate product identity from registration mailbox authorization

The first-release replacement accepts Google and Apple for Product Sign-In while
supporting only Gmail as a Mail Provider. Google registration requests both
identity and Gmail access as part of onboarding. Apple registration continues
directly into Google authorization for the Gmail mailbox. Microsoft sign-in is
deferred. This keeps multiple sign-in choices at the cost of a second provider
authorization step for people who register with Apple.

The application creates or authorizes the Mailbox Connection only after verifying
that the user granted the required Gmail access. Identity permission and mailbox
permission remain separate, even when the interface obtains them during one
journey. An Apple relay address, a Google identity token, or a matching email
address cannot substitute for a Gmail grant. If Gmail is unavailable, consent is
cancelled, or mail permissions are declined, retain the Product Account and show
resumable mailbox setup. The user can retry or choose another Google account.
Do not present a connected inbox until Gmail authorization succeeds.

Apple and Google may become alternate sign-ins for the same Product Account
through explicit linking that verifies both identities. Never merge Product
Accounts because their email addresses match. Adding another Gmail Mailbox
Connection does not automatically add that Google identity as a Linked Sign-In.

Retain Convex, but replace Apple-specific assumptions in authentication and
affected backend contracts. Product Account identity, device trust, and mailbox
authorization remain distinct. Preserve End-to-End Encrypted Product Sync and
device-local provider credentials. Each new device obtains its own Gmail grant
and receives or recovers the Product Sync keys independently of Product Sign-In.
New-device enrollment uses approval from an existing trusted device, with a
user-held Recovery Key as the fallback. Missing local keys never silently create
replacement account keys or reset an existing Product Account. If every trusted
device and the Recovery Key are lost, explain that encrypted product data cannot
be recovered. Any reset of that user's encrypted product data must be explicit
and must leave provider mail untouched. Recent-authentication, revocation, and
deletion flows must enforce these boundaries for both Sign-In Providers.

The requested database clearing is a one-time reset of the unused development
data during replacement cutover. It is not the production recovery flow and does
not authorize a global database reset when a user cannot unlock an account.

This supersedes the Apple-only sign-in prerequisite for the replacement. It
reaffirms the privacy boundaries in
[ADR 0001](0001-end-to-end-encrypted-product-sync.md) and
[ADR 0002](0002-device-held-mail-provider-tokens-with-push-relay.md), while requiring
new implementations of their Apple-specific authentication steps. Enrollment and
recovery protocol details still require implementation design and verification.
Provider facts and supporting sources are recorded in the
[rewrite research](../research/expo-react-native-rewrite.md#registration-and-gmail-authorization).
