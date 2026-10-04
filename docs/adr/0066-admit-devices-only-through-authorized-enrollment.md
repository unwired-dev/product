---
status: accepted
---

# Admit devices only through authorized enrollment

A device becomes a **Trusted Device** only when an existing Trusted Device approves
it or the **Recovery Key** unlocks it. **Product Sign-In** alone admits nobody
except the device that creates a Product Account's keys. This replaces the
account-wide rule in
[ADR 0020](0020-revoke-devices-with-sync-key-rotation.md) that refuses every
previously unseen device identifier once an account has a revocation tombstone.
That rule stopped a removed device from rejoining under an invented identifier,
and it also stopped every legitimate new device. The rest of ADR 0020 stands.
Issue #750 owns the implementation.

## Decision

Every device after a Product Account's first starts as a **Pending Device**,
whether or not the account ever removed a device. A Pending Device is a separate
backend record. It is never a Trusted Device record, so everything that reads
Trusted Devices excludes it by construction: account operations, push routing,
Product Sync reads, the device list, the rotation acknowledgement set and the
Trusted Device limit.

A Pending Device authenticates with Product Sign-In and its own device-only
credential. It may create or renew its own enrollment request, read that
request's status, receive the key ring sealed to it, submit Recovery Key proof,
drop its own record, and delete the Product Account after a recent interactive
Product Sign-In. It may do nothing else. It never receives a rotation transition
or a recovery envelope before it is authorized.

Approval by a Trusted Device is the admission. The approver enters the Pending
Device's **Enrollment Code**, and that single step creates the Trusted Device
record and delivers the sealed key ring. The approver must already hold the
account's newest key epoch, including a pending one, and seals that ring. The
admitted device is recorded as acknowledged at that epoch and never needs a
transition. A Trusted Device that has not adopted a pending epoch adopts it
first.

Each recovery envelope is published with a verifier: a digest of a value derived
from the Recovery Key for this purpose only. The Recovery Key is random 256-bit
material, so a plain digest is sufficient. A Pending Device submits the derived
value. When it matches, the backend admits the device and returns the envelope in
the same step. A wrong value leaves the device pending with its current
Enrollment Code. The first device, Recovery Key replacement and Device Revocation
all publish the verifier with the envelope they write.

While a key rotation is pending, only the replacement Recovery Key issued by the
revocation admits a Pending Device, and it yields the newest epoch. The previous
Recovery Key keeps working for devices that are already trusted until the
rotation completes, as ADR 0020 describes. It admits no new device.

A removed device's own identifier and Trusted Device Credential stay refused with
the revocation tombstone. Under a new identifier it is a Pending Device like any
other.

Each device identifier has at most one Pending Device record, and each Product
Account at most three. A record expires with its Enrollment Code and does not
count toward the Trusted Device limit, which is enforced at admission. Trusted
Devices learn of a request when they synchronize or refresh; no push is sent.

## Why

The transition of a pending rotation is sealed with the committed epoch's key,
which the removed device still holds. Any path that makes a device trusted before
authorization would hand that device the transition and let it block rotation by
never acknowledging. Keeping unauthorized devices out of the Trusted Device set
removes both problems without a per-check filter that one caller could miss.

The removed device may also know the previous Recovery Key. If that key admitted
a device during a pending rotation, the removed device could recover to the
committed epoch under a new identifier and then fetch the transition. Restricting
admission to the replacement Recovery Key closes that path.

One admission path for every account avoids a second, rarely exercised path that
applies only after a removal. The product has no users yet, so no existing
registration needs to be preserved.

## Consequences

- A person who loses every Trusted Device and holds only the previous Recovery
  Key while a rotation is pending cannot regain access. If a remaining device
  never reconnects, that rotation never completes. Deleting the Product Account
  is the only path left.
- A removed device with a live Product Sign-In can delete the Product Account's
  synchronized data. It can read none of it. In-app account deletion must stay
  available to a person with no Trusted Device.
- A device waiting for authorization cannot authorize Gmail or use the product.
- The legacy Swift client registers a second device directly as trusted. That
  stops working and the client is not adapted.
- The identifier-history migration in ADR 0020 served the unseen-identifier lock
  and is no longer needed to admit devices.
