# Swift Documentation Patterns

Use Swift documentation comments for public or cross-feature app surfaces when the caller needs more than the type signature.

## Document With Examples

Add `///` documentation with an example for:

- Protocols used as service boundaries between SwiftUI views and backend or storage code.
- Types that model backend responses, privacy boundaries, or persisted records.
- Async functions that call a backend, filesystem, keychain, database, or mail provider.
- Initializers with environment requirements such as `CONVEX_URL`.
- Preview or test doubles intended to be reused by another feature.

Do not add documentation comments that only repeat property names or obvious SwiftUI layout behavior.

## Shape

Prefer this structure:

```swift
/// Fetches backend health without sending account, mailbox, provider, or device data.
///
/// Use this service boundary from smoke-path views instead of constructing
/// Convex HTTP requests directly in SwiftUI.
///
/// Example:
/// ```swift
/// let service = ConvexBackendHealthService(
///   convexURL: URL(string: "https://example.convex.cloud")
/// )
/// let response = try await service.health()
/// ```
protocol BackendHealthChecking {
  func health() async throws -> HealthResponse
}
```

## Rules

- Start with behavior from the caller's point of view.
- Include examples for reusable protocols, service methods, and data models.
- Keep examples small enough to paste into a test or preview.
- Name required environment variables and setup assumptions.
- Mention privacy boundaries when code intentionally avoids mailbox data, provider tokens, categories, or encrypted user data.
- Prefer `///` for symbols and `//` only for implementation notes inside complex bodies.

