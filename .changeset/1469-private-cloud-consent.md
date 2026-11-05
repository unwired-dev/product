---
'@private-email/mail-core': minor
'@private-email/localization': patch
'@private-email/mobile': minor
'@private-email/macos': minor
---

Turn on Private Cloud separately for each Mail Profile on iPhone, iPad and Mac. Settings'
**Privacy & Data** adds a **Private Cloud** group: its **Use Private Cloud** switch is off by
default, needs that Profile's Mail Assistance, asks for confirmation before turning on and is
saved only on this device with Mail Assistance Enablement. **Check** explicitly reports whether
Apple Private Cloud Compute is ready, without generating anything. Mail Assistance Enablement
now records `privateCloud` Profiles, `privateCloudEnabled` reads them, `setPrivateCloud`
saves that consent and `getFailedSave` names a failed save; `NativeMailAssistance`'s
`setMailAssistance` receives the Private Cloud Profiles, and `createPrivateCloudReadiness`
checks a `NativePrivateCloud`. No operation uses Private Cloud Compute yet.
