---
'@private-email/mail-core': minor
---

Synchronize Mail Profile definitions and connection ownership through end-to-end
encrypted Private Sync. The registration store can now create, rename and remove
Profiles and move a Mailbox Connection between them. A Profile named offline is
published once Private Sync is reachable. Moving a connection and removing a Profile
need Private Sync; they report `profile-changed` when another device wrote first,
and removal reports `profile-in-use` while the Profile still owns a connection.
Pending Profiles survive authorized re-enrollment after device-key loss. Removal
fences delayed first publication, and confirmed versions prevent older records
from reviving a removed Profile or regressing ownership.
Confirmed reads and writes survive later publication failures and relaunch.

- The registration snapshot lists the other Profiles (`profilesOf`) and each
  connection's synchronized `profile`.
- `NativeRegistrationVault` adds `sealProfileRecord`, `openProfileRecords` and
  `recordProfiles`.

The apps do not offer creating another Profile yet.
