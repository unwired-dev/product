# Keep Mail Assistance on device and input-bound

## Status

Accepted.

## Context

Compose, response, and understanding features need a shared model boundary before they add user interfaces. Mail and Draft content is private, can contain adversarial instructions, and can change while inference is running. The application must also remain useful when the system model is unavailable.

Apple's Foundation Models framework is available only on iOS 26, iPadOS 26, and macOS 26. Its availability distinguishes device eligibility, Apple Intelligence configuration, and model readiness; locale support and generation failures expose additional language, resource, rate-limit, refusal, and context states.

## Decision

Raise every Apple target's deployment floor to version 26 and place generative assistance behind the product-owned `MailAssistanceEngine` protocol. The system adapter uses `SystemLanguageModel` with no tools and no prewarming. It creates a fresh session only after explicit invocation, gives the model fixed product instructions that treat all mail content as untrusted data, and supplies one typed JSON request containing the explicit user operation and bounded context.

An Assistance Context can contain only already-local authored Draft text, an explicit selection, recipient display information, and already-local source-message text. The engine has no provider, attachment, remote-content, Product Sync, backend, persistence, tool, or network dependency. Assistance Contexts above 24,000 characters or 32 source messages fail before inference.

Every request carries opaque Draft, selection, and Thread revision tokens plus its Mail Profile identity. The returned Assistance Preview carries the same values and is applicable only while all of them still match. Cancellation, failure, refusal, unavailability, and stale input produce no source mutation because the engine returns a value and never edits a Draft or message.

Map system availability and generation failures into product-owned states. A deterministic engine provides success, clarification, unavailable, failure, and cancellation behavior without a live model.

## Consequences

- Mail remains usable when assistance is unavailable; child features decide how to explain the specific state.
- Opening a composer cannot start model preparation because this foundation is not connected to composer lifecycle and never calls `prewarm`.
- Downstream features must build Assistance Context explicitly and revalidate the returned preview before insertion or display.
- Profile-scoped device enablement and each Compose, Response, Understanding, and Translation capability remain separately reviewable on the shared boundary.
- Translation continues to require Apple's dedicated Translation framework rather than this generative engine.
