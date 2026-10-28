---
status: accepted
---

# Prefer Private Cloud Compute for separately authorized mail assistance

The product owner confirmed [Private Cloud Mail Assistance](../product/private-cloud-mail-assistance.md)
on 2026-10-28. Retain the existing on-device mode and Mail Assistance Enablement
gate, and add a separate default-off, device-local Product Account and Mail
Profile opt-in that prefers Apple's Private Cloud Compute (PCC). A larger model
and broader relevant context can improve requested mail understanding and reply
quality, at the cost of sending authorized context off device and depending on
Apple's service, eligibility and daily quotas. The operational owner defines
the complete initial scope, lifecycle, follow-ups and release checks; this
accepted decision is not implementation or qualification evidence.

Use native Foundation Models sessions from the device to Apple's PCC, rather
than a product-backend inference service. Apple's
[integration guide](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)
provides the system model selection, availability and quota interfaces on OS 27.
Keep readable inference inputs, outputs and provider credentials out of the
product backend. This fits the Apple-API integration boundary in
[ADR 0067](0067-keep-native-code-to-a-minimal-vault.md); it does not transfer
shared application policy into native code. Managed-entitlement approval and
[developer eligibility](https://developer.apple.com/private-cloud-compute/)
remain prerequisites, alongside eligible Apple Intelligence devices and network
access. Their absence must not block core mail or the existing local mode.

Application-owned retrieval assembles relevant context within the authorized
operation and Profile. The PCC mode can fetch missing Thread content and admit
supported attachment content instead of inheriting the local engine's
already-local text restrictions. Larger inputs still need bounded stages with
source attribution and coverage checks; a larger context window does not ensure
factual accuracy or complete coverage. Treat mail and attachments as untrusted
data, preserve source-revision and lifecycle fences, and keep generated changes
behind explicit undoable acceptance. Compatible local fallback may handle
unavailability or exhausted quota only when it can complete the same operation,
with disclosure; refusal cannot trigger another-model retry. Do not silently
truncate context to make a request fit. Evaluation determines processing budgets
and reasoning settings without promising arbitrary-file support or fixed quotas.

## Scoped supersession

For this separately authorized mode only:

- [ADR 0052](0052-keep-mail-assistance-on-device-and-input-bound.md): replace
  the on-device-only, already-local bounded-text and attachment/network exclusion
  clauses for the operations and contexts authorized by the operational owner.
  The existing local mode retains its input limits and no-cloud-fallback contract.
- [ADR 0059](0059-replace-the-client-for-a-shared-cross-platform-product.md)
  and [ADR 0069](0069-expand-the-apple-launch-to-power-user-mail.md): qualify
  their retained on-device-only assistance requirement with this optional mode,
  without making PCC a core-mail or on-device release gate.
- [ADR 0073](0073-separate-external-agent-access-from-on-device-assistance.md):
  qualify its built-in assistance privacy boundary to include separately opted-in
  PCC. External Agent access and its consent, permissions and milestone remain
  separate; neither opt-in authorizes the other.

[ADR 0053](0053-keep-mail-assistance-enablement-device-local.md) remains the
enablement and lifecycle foundation; existing consent never grants PCC access.
[ADR 0068](0068-allow-device-local-background-message-summaries.md) and
[ADR 0072](0072-allow-reviewed-post-launch-mail-commitments.md) retain their
background on-device requirements. Background PCC is a deferred evaluation,
not authorization under this decision. Translation retains its dedicated Apple
Translation boundary. Other privacy, encryption, isolation, retention, delivery
and explicit-review requirements remain in force.
