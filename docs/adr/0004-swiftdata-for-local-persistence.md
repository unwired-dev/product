# SwiftData for local persistence

The Apple client will use SwiftData first for local persistence because the product should stay Apple-native and define models in Swift code rather than writing SQL schemas. This favors developer speed, SwiftUI integration, and minimal external dependencies, while accepting that advanced migrations, encryption strategy, sync-engine internals, and cache behavior may need careful validation as the mailbox model grows.
