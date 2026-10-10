---
status: accepted
---

# Seal key rotations to each remaining Trusted Device

Accepted on 2026-10-10 for
[#753](https://github.com/unwired-dev/product/issues/753), before runtime
implementation. The replacement's removal foundation
([#602](https://github.com/unwired-dev/product/issues/602),
[PR #751](https://github.com/unwired-dev/product/pull/751)) seals a new ring with
the committed account key. The removed device holds that key: backend read access
therefore defeats the authorization fence. Seal each complete ring independently
to the remaining devices instead, and activate removal and recovery together
after the person confirms the replacement Recovery Key.

## Security boundary and scope

Protect against all secrets held by the removed device at removal, including its
device private key, historical account keys, enrollment secrets and previous
Recovery Keys, combined with read access to current and retained backend payloads.
None may unlock the epoch created by its removal or a later epoch.

This guarantee excludes active backend tampering or public-key substitution,
compromise of a remaining Trusted Device, and access subsequently granted through
a new authorized enrollment. Preserve existing enrollment protections; narrowing
this issue's threat model is not permission to weaken them. Previously known keys
and ciphertext remain usable: removal cannot erase historical data or remotely
erase offline copies.

This decision covers the replacement mobile and Mac hosts, their shared native
encryption/key storage, and Convex. Preserve Google and Apple Product Sign-In and
the existing recent-authentication requirement. There are no existing users and
no existing-registration migration. Do not adapt the legacy Swift client or reopen
legacy enrollment paths that bypass Pending Device authorization.

## Device key and envelope binding

Create an account-scoped, long-lived encryption key pair per installation. Store
the private key in native, device-only secure storage under the existing vault
policy. Bind the public key at first-device key setup or authorized enrollment.
A trusted registration's public key is immutable; Product Sign-In alone cannot
replace it. Losing the private key requires fresh authorized enrollment through
another Trusted Device or the current Recovery Key. The abandoned registration
remains until explicitly removed.

Use CryptoKit's supported
[RFC 9180 HPKE construction](https://www.rfc-editor.org/rfc/rfc9180.html#section-5.1.1):
DHKEM(X25519, HKDF-SHA-256), HKDF-SHA-256 and ChaCha20-Poly1305, in base mode
for rotation. This reuses enrollment's supported ciphersuite without retaining
an Enrollment Code as a rotation secret. Each seal uses a fresh HPKE sender
context. Length-prefixed info and authenticated data bind the purpose, protocol
version, Product Account, recipient Trusted Device, exact recipient public key
and epoch. Reject unsupported versions, mismatched bindings and malformed rings;
validate the declared epoch, 32-byte account keys and retention of already-held
historical keys before durable adoption. Never seal a new ring with an earlier
shared account key or derive a survivor's private key from shared account,
recovery or enrollment secrets.

The long-lived key is separate from the one-time enrollment key. Enrollment
authorization binds the candidate long-lived public key along with the current
Pending Device request in the enrollment envelope's authenticated context;
changing either invalidates that authorization. Admission
checks the same binding when creating the immutable trusted registration. Preserve
the code-protected HPKE PSK enrollment envelope, code entropy, request renewal
fences, current approver membership, recovery proof, durable adoption and atomic
confirmation rules of
[ADR 0066](0066-admit-devices-only-through-authorized-enrollment.md) and the
[Product Sync companion](../architecture/private-product-sync.md#trusted-device-enrollment).
The exclusion of active backend tampering for rotation does not authorize removing
enrollment's public-key-substitution protection.

Native key custody and persist-before-return requirements in
[ADR 0067](0067-keep-native-code-to-a-minimal-vault.md) continue to apply. Public
keys, sealed envelopes and non-secret proposal metadata may cross the bridge;
private keys and plaintext rings may not. Recovery Key text keeps only its
existing presentation exception.

## Prepare, confirm, activate

The initiating Trusted Device adopts the latest ring, captures the current epoch,
recipient roster/public keys and recovery revision, and prepares a fresh epoch
with the complete historical ring, one envelope per survivor and a replacement
Recovery Key envelope/verifier. Give the proposal a durable identity and retain
enough local state to reconcile interruption. Prepared keys cannot protect ordinary
writes before backend commitment.

Show the replacement Recovery Key and require confirmation that it was saved
before submitting activation. Cancellation leaves backend state unchanged. A
rejected proposal is never presented as active. A roster, epoch or recovery
conflict requiring a fresh proposal and key requires showing and confirming that
new key again; a discarded proposal's confirmation cannot authorize it.

Activation requires recent Product Sign-In, renewed if preparation outlasts the
existing freshness window, and authenticated Trusted Device proof. Convex validates
the captured epoch, exact recipient roster and public keys, recovery revision and
exact envelope coverage. In one transaction it removes the target and its push
routes, activates the new epoch, publishes exactly one envelope for each remaining
Trusted Device including the initiator, and replaces the Recovery Key envelope
and verifier. Missing, extra, duplicate, foreign-account, removed-device and
Pending Device recipients fail. Concurrent enrollment, removal or recovery changes
cannot commit a stale snapshot. All changes commit or none do. Preserve
installation-level self-removal refusal, tombstones, revoked-device authorization
and reconnect purge behavior.

Persist proposal identity and committed result, or an equivalent durable receipt,
so retries and queries distinguish rejection, successful activation and successful
activation followed by a later rotation. Duplicate submission cannot rotate twice
or activate a different proposal. A target tombstone or the account's current
epoch alone does not prove this proposal's Recovery Key activated. Receipts and
backend state contain no plaintext keys. Reconciliation must not present an
uncommitted or subsequently superseded Recovery Key as current.

## Offline adoption, writes and recovery

Retain each remaining device's latest complete ring envelope until superseded or
that device is removed. A survivor reaches the newest epoch directly after any
number of missed rotations, without intermediate transitions or a Recovery Key,
and retains historical access. Save adopted keys durably before acknowledging.
Acknowledgements track adoption only: they never delay activation, later removals
or recovery replacement, and never discard another offline device's only catch-up
path. Stale or duplicate acknowledgements cannot regress state.

Reject old-epoch Product Sync writes immediately after activation. Preserve local
changes, adopt the latest ring and reseal on retry while retaining record-conflict
checks; no generic queued-write system is required. An enrollment approver must
hold the latest ring. Confirmation overtaken by a rotation fails and requires
fresh authorization for the current epoch. Pending Devices receive no rotation
envelopes and count as neither recipients nor acknowledgements.

The replacement Recovery Key becomes current in the activation transaction. The
previous Recovery Key no longer provides current recovery access and receives no
envelope containing the new epoch; it may still open historical ciphertext already
obtained. Only the current Recovery Key can restore access after all Trusted
Devices are lost. Losing it leaves the existing account-deletion path. Recovery
envelope/verifier publication and Pending Device proof/confirmation protections
remain intact.

## Supersession and consequences

### Staged native coordination exception

The review decision panel on 2026-10-10 considered moving this issue's flow
coordination into TypeScript now, or extending the existing native coordinator
until the already ordered migration. All three panelists (`claude-fable-5-1`,
`gpt-6.1-sol`, `gpt-6-astra`) selected the latter: #757 depends on #753 and owns
moving initialization, enrollment, recovery and rotation coordination.

For #753 only, preparation/activation sequencing, retry/reconciliation and the
corresponding native synthetic backend may extend the existing native flow.
This temporary exception to ADR 0067 ends with #757. It authorizes no new native
application subsystem and changes neither key/credential custody nor durable
storage before acknowledgement. The TypeScript ownership decision and its
ordered #756–#759 migration remain in force.

### Protocol supersession

- Partially supersedes
  [ADR 0020](0020-revoke-devices-with-sync-key-rotation.md): replace shared-key
  pending transitions, pending-or-committed write acceptance and acknowledgement-gated
  commitment/recovery publication. Offline survivors cannot block completion or
  successive removals. Retain its authorization, self-removal, tombstone, purge
  and historical-data limits.
- Partially supersedes
  [ADR 0001](0001-end-to-end-encrypted-product-sync.md): removal uses prepare,
  confirm, then activate, replacing post-removal local Recovery Key confirmation
  and pending-rotation recovery/sign-out exceptions. Other recovery-publication,
  privacy, conflict and key-custody requirements stand.
- Partially supersedes
  [ADR 0066](0066-admit-devices-only-through-authorized-enrollment.md) and
  [#750](https://github.com/unwired-dev/product/issues/750)
  ([PR #761](https://github.com/unwired-dev/product/pull/761)): there is no
  acknowledgement-waiting rotation or temporary previous-Recovery-Key allowance
  for already-trusted devices. Current-epoch authorization and durable confirmation
  remain mandatory; every other enrollment/recovery protection stands.
- Replaces the corresponding #602/#750 protocol passages in the
  [Product Sync companion](../architecture/private-product-sync.md). Publication
  of this decision does not claim runtime implementation or qualification.

Per-device envelopes add storage and immutable device-key lifecycle requirements,
but remove reliance on backend read authorization to hide new account keys from
a removed device. Keeping shared-key transitions was rejected because the
removed device can decrypt retained backend copies. Waiting for acknowledgements
was rejected because an indefinitely offline survivor blocks further removals
and delays recovery activation.

Implementation evidence must cover removed secrets against every current and
retained payload/envelope type, successive removals, recipient/account/epoch
binding failures, positive survivor/current-recovery decryption, atomic races,
lost replies and restarts, offline catch-up, fencing and preserved enrollment.
Mocked journeys remain separate from native/integration evidence under
[ADR 0060](0060-pair-mocked-mail-journeys-with-real-integration-evidence.md).
Unavailable Apple OS 27 native checks remain deferred and required before release.
