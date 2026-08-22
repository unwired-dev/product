# Integrate Profile-scoped Settings behind the release gate

Status: released by issue #133 after the gate's dependencies closed. The adaptive Settings
experience is now the only Settings presentation; the legacy Account Settings sheet was removed.

## Status

Accepted.

## Context

Mail Profile ownership, lifecycle transactions, per-window selection, Categories, notifications,
and Sending Identities landed as separate slices. The remaining integration must prevent a
Profile-owned setting from leaking into another Profile, preserve pre-Profile data for older app
versions, and expose lifecycle controls without prematurely replacing production Account Settings.

Some Settings are intentionally device-local. Moving those values into Product Sync merely for a
uniform Settings implementation would weaken the privacy boundary and cause one window or device
to redirect another.

## Decision

Resolve every Profile-owned Settings store from the active Profile's `MailProfileRecordScope`.
Compose preferences, Signatures, Inbox preferences, Categories, Templates, Sending Identities,
and proactive-suggestion preferences receive independent local and encrypted Product Sync
namespaces. Shared session caches retain one store per scope so two windows using different
Profiles cannot retire or replace each other's state.

Keep the migrated Default Profile on the deployed Product Account-scoped identifiers. New Profiles
use opaque `mail-profile-v1.<profile-id>` identifiers. An older client therefore continues to read
and write the Default Profile in place and ignores records belonging to Profiles it does not
understand; migration does not copy, reset, or fork existing preferences.

Add a Mail Profiles destination to the adaptive Settings registry. It uses the existing atomic
lifecycle service for creation, reviewed duplication, connection transfer, and deletion. Deletion
preflight counts Profile Drafts plus connection-owned Outbox attempts and pending Provider Mail
Actions before submitting the current lifecycle review. Startup Profile selection remains
Product-Account-scoped device state.

Retain the current production Account Settings entry point. The adaptive Settings entry point and
Mail Profiles destination remain development-only until the complete Settings release gate has
passed on iPhone, iPad, and macOS, including mixed-version and simultaneous-window validation.

Product Sync export continues to include encrypted Profile ownership and Profile-scoped records.
Provider credentials, device-local Settings, window restoration, Profile Lock, and Startup Profile
remain outside the export.

## Consequences

- Editing one Profile cannot mutate another Profile's local or synchronized preferences.
- Existing users and older clients keep one lossless Default Profile view of deployed settings.
- Multiple windows can retain independent Profile stores without cache retirement races.
- Lifecycle operations are reviewable and atomic, while offline names and styles remain retryable.
- The complete experience is implemented for release validation without changing the production
  Settings entry point.
