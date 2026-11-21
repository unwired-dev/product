---
status: accepted
---

# Report a Trusted Device's kind and last activity in sealed records

## Context

On 13 November 2026 the product owner approved the Trusted Devices rows of
[#2107](https://github.com/unwired-dev/product/issues/2107): each row shows the
device's kind (iPhone, iPad or Mac) and when it was last active, with the exact
time. Convex's `trustedDevices` table already keeps a platform and a `lastSeenAt`
for its own checks, but `platform` cannot tell an iPhone from an iPad, and showing
a time the backend derives from requests would make device activity readable
product data on the server.

## Decision

Each Trusted Device reports itself in a **Trusted Device Record**: a Private Sync
record sealed with the account's key ring, under the opaque identifier native code
derives from the kind `device` and the device's own Trusted Device identifier. It
holds the device identifier, a version, the kind as text (`iphone`, `ipad` or
`mac`) and when the device was last active, in milliseconds since 1970. A record
opens only under the identifier its own device determines, so a record served
under another device's identifier is ignored.

A device writes its record when it synchronizes and its record is missing, does not
open, names another kind, or is 15 minutes old or more. Reading the account's
Trusted Devices reads every record; Convex's roster still decides which devices are
listed, so a removed device's record is never shown. Nothing derives the time shown
from `lastSeenAt` or request logs.

## Consequences

The backend stores one more opaque identifier and ciphertext per device, and sees
it rewritten at most about every 15 minutes while the device is in use. A device
registered before this change, or one whose record does not open, is listed with
neither kind nor activity until it next synchronizes; no device is dropped or
approved again. A kind a newer client adds still opens and is shown with the neutral
symbol. Records of removed devices stay until the account is deleted.
