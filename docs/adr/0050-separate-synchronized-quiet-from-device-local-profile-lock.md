# Separate synchronized Quiet from device-local Profile Lock

## Status

Accepted.

## Context

Mail Profiles need two interruption controls with different trust and synchronization boundaries. Quiet is user workflow intent that should converge across Trusted Devices. Profile Lock protects what one physical device can reveal and must not create a synchronized authentication secret or weaken background mail reliability.

## Decision

Store each Profile's Quiet state in the existing end-to-end encrypted Mail Profile definition. Quiet is either inactive, indefinite, or active until one absolute timestamp. Trusted Devices merge it through the existing per-field Profile conflict contract. Active Quiet suppresses visible notifications and proactive suggestions, while an unavailable authoritative Profile state fails closed for notification presentation.

Store Profile Lock enablement and its background grace period only in device-local preferences, scoped by Product Account and Profile. Enabling, disabling, and unlocking use the operating system's device-owner authentication policy, which permits Face ID, Touch ID, or the device passcode. The default background grace period is five minutes; explicit lock and protected-data loss lock immediately.

Lock is a presentation boundary, not a synchronization boundary. The mail shell remains alive but hidden from rendering, hit testing, and accessibility while a lock overlay is shown, so mailbox synchronization, local indexing, Outbox, and Scheduled Send work continue. Lock removes the Profile's Core Spotlight domain. Deep links still enter the concealed shell and cannot reveal content before authentication. A Profile with device-local lock enabled suppresses content-bearing notification presentation on that device.

## Consequences

- Quiet and Resume converge without exposing their plaintext to the backend.
- A device can choose stronger local protection without changing another Trusted Device.
- Unknown Profile ownership or unreadable synchronized Quiet state cannot accidentally produce a visible notification.
- Locking does not suspend background mail work, but Spotlight results for that Profile must be rebuilt by the indexing path after a later authenticated unlock.
- The integration layer that adds multi-Profile selection must call the interruption model with the selected Profile identity; the Default Profile remains the safe fallback until then.
