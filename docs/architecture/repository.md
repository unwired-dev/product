# Repository documentation routing

Reviewer-only under the [implementation and review workflow](../agents/implementation-review.md).

## Bootstrap references

The [Expo bootstrap](../expo-client.md) uses Effect v4 and native split-view
navigation. Full [platform qualification](../qualification/expo-react-native-client.md)
remains required before release.

One root workspace and lockfile use a shared catalog and named `mobile` and `macos`
catalogs under [ADR 0064](../adr/0064-isolate-mobile-and-macos-native-dependencies.md).
The replacement's [isolated Mock Mail Sessions](../mock-mail-sessions.md) follow
[ADR 0060](../adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md).

The [78-ticket coverage index](../qualification/expo-rewrite-ticket-coverage.md)
tracks ticket and dependency coverage. Read the accepted rewrite decisions through
[the architecture index](README.md).
