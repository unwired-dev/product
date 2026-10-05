# Identity: architecture notes

Reviewer-only companion to [docs/product/identity.md](../../product/identity.md).
Read under the [implementation and review workflow](../../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Scope

Product Account identity and device trust apply to the replacement. Advanced
Profiles are follow-up work; Default Profile and the deployed Profile Record
Scope describe prototype migration behavior.

## Decisions and scope

- [Accepted replacement scope](../../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
- [Authorized device enrollment](../../adr/0066-admit-devices-only-through-authorized-enrollment.md)
- [Separate product identity from registration mailbox authorization](../../adr/0061-separate-product-identity-from-registration-mailbox-authorization.md)
- [Linked Google and Apple sign-in](../../linked-sign-in.md) for the replacement's explicit linking behavior
- [Separate encrypted Mail Profile ownership from legacy records](../../adr/0048-separate-encrypted-mail-profile-ownership.md)
- [Scope each window to one Mail Profile](../../adr/0050-scope-each-window-to-one-mail-profile.md)

[The documentation index](../../README.md) explains ADR precedence and separates
current replacement work from prototype maintenance and historical plans.

## Accounts and Profiles

- A Profile-scoped query requires an explicit **Mail Profile**

## Sensitive operations and device revocation

- For owner revocation, the Apple client retains and submits the selected Trusted Device ID, while Convex retains and resolves its account-scoped revocation target after sign-out; unregistering, reconnecting, or a late unregister cannot preserve live access or remove the durable identifier tombstone

- Every **Trusted Device** whose client supports device credentials presents its device-only **Trusted Device Credential** to Product Account, Product Sync, and push-relay APIs; routine reconnects preserve a valid credential so concurrent in-flight requests remain authorized, while a missing or stale credential is replaced; a Trusted Device ID alone is not authentication proof

- A separate `pendingDevices` record holds the device-only credential digest, current one-time public key and opaque approval. Its ID also identifies its enrollment request. No Trusted Device query, push route, ordinary Product Sync operation or rotation acknowledgement treats a pending record as trusted. Admission transactionally creates the Trusted Device with the same credential digest and the durably adopted newest epoch, then removes the Pending Device.

- A device identifier has at most one Pending Device record, and an account has at most three unexpired Pending Devices. Credential reissue after a lost registration reply clears earlier authorizations. Expired records are replaced or cleaned up in bounded batches; the Trusted Device limit is checked only at admission. A pending sign-out races with admission in one transaction: it removes the pending record or proves and unregisters the admitted installation with the same credential.

- Removed installation identifiers and credential proofs remain refused through the account-scoped tombstone and minimal revocation targets. A new identifier gets the ordinary Pending Device path. ADR 0066 supersedes the account-wide unseen-identifier refusal, its migration gate and mutation, and its identifier history. No existing-user migration is required; development data with the removed fields must be cleared before deploying the new schema.
