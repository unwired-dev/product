# Keep Mail Assistance enablement device-local

## Status

Accepted.

## Context

On-Device Mail Assistance can process private mail and Draft content only after an explicit request. A person may trust that processing on one device but not another, and a synchronized opt-in could silently enable it on a newly trusted device. Profile Lock must also prevent retained assistance state from surviving the transition to concealed content.

The feature must remain understandable when the system model is unavailable because of hardware eligibility, Apple Intelligence configuration, model readiness, locale support, or temporary resource pressure.

## Decision

Store Mail Assistance enablement as a device-local boolean keyed by Product Account and Mail Profile. It defaults off for each key, never enters Product Sync, and is cleared with other device-local Product Account data at sign-out.

Enabling the preference only exposes explicit assistance actions. It does not prewarm the model, check availability implicitly, or begin inference. Account Settings provides an explicit availability check and explains the product-owned unavailability state without changing mail behavior.

The assistance view model owns every active availability check, generation task, retained request, error, and preview. Disabling assistance, switching Profiles, or concealing the Profile cancels active work and clears those values. Unlocking the Profile does not restore a discarded preview. Quiet State suppresses proactive suggestions but does not block a person's explicit assistance action.

## Consequences

- Enabling assistance on one Profile or device does not enable it anywhere else.
- Product Account removal clears the account's device-local enablement keys.
- Mail remains fully usable when assistance is disabled or unavailable.
- Feature surfaces must call the engine only from an explicit action and must use the lifecycle owner so lock and Profile transitions cancel work consistently.
- A person must request generation again after Profile Lock or a Profile switch.
