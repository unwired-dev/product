# Scope each window to one Mail Profile

## Status

Accepted.

## Context

Mail Profile ownership is synchronized and encrypted, but the Profile a person is currently viewing is presentation state. Synchronizing an active Profile would make one device or window unexpectedly redirect another. Treating the Startup Profile as the synchronized Default Profile would also collapse two distinct decisions: lossless ownership migration and where a new local window begins.

Provider synchronization, queued delivery, and notifications must continue for inactive Profiles. Presentation, search, and actions must never aggregate connections from different Profiles.

## Decision

Resolve one active Profile per app scene in this order: an explicit targeted route, the scene's restored device-local Profile, the device-local Startup Profile, then the synchronized Default Profile. Ignore identifiers that are absent from the current encrypted Profile snapshot. iPadOS and Mac Catalyst support multiple scenes so two windows may hold different active Profiles concurrently.

Filter every mail-shell connection input through the active Profile's encrypted connection assignments. Keep automatic provider synchronization and Outbox resumption account-wide so inactive Profiles remain current. A manual Refresh All action is scoped to the active Profile because it is a visible workspace action.

Use a curated Profile appearance vocabulary. The switcher and message toolbar show the Profile name, SF Symbol, color, and a textual symbol/color description so color is never the only identity cue. Profile-aware local notifications use the same name and textual appearance, carry only the opaque Profile identifier, and route through `unwired-mail://mail?profileId=<opaque-id>`.

Keep the active Profile in scene-local storage and the Startup Profile in Product-Account-scoped device-local preferences. Deep-link routing retains a pending opaque Profile target across account bootstrap, then consumes it once the encrypted Profile snapshot is available.

Before changing Profile, synchronously park the latest observed composer value under its source Profile. The active Profile changes only after parking succeeds; a parking failure leaves the window in the source Profile and exposes the error. Returning to that Profile resumes the parked composer.

## Consequences

- Restoring or opening one window cannot redirect another window or another device.
- Normal mail navigation fails closed while Profile ownership is unavailable instead of briefly combining Profiles.
- Inactive Profiles continue background synchronization without appearing in the active window.
- Search, Spotlight, and notification producers can use one opaque Profile deep-link contract without including Profile names or mail content.
- Profile lifecycle, connection transfer, Quiet, Lock, and complete Settings integration remain owned by their separate child issues.
