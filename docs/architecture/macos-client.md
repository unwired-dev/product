# Macos client: architecture notes

Reviewer-only companion to [docs/macos-client.md](../macos-client.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Host ownership

The `macos` catalog pins React Native macOS 0.81.9, React Native 0.81.6 and React
19.1.4 in the root workspace and lockfile. This follows the amended
[ADR 0064](../adr/0064-isolate-mobile-and-macos-native-dependencies.md), which
supersedes the issue's original separate-lockfile requirement. Mac views and
native adapters live in `apps/macos`; `mail-core` imports no UI framework.

Metro redirects React and React Native imports, including subpaths, to this
host's packages. Its startup module also comes from React Native macOS. The
production source-map check rejects the mobile renderer, Expo, React DOM and
backend code, checks the shared fixture against disk, and verifies native
autolinking. The host admits `react-native-webview` as its only additional native module
for the isolated message reader. Adding another requires an explicit update to
that check.

AppKit owns stable window identities and menu routing. One React factory and one
JavaScript mailbox runtime live for the application process. Each window mounts
its own React root and owns its selected message. Closing a window releases its
view; opening another starts with no selection. Reading leaves unread flags unchanged. Explicit read/unread actions persist
and update all windows without changing their selections.

## Build and run

The checked-in Objective-C++ host, Podfile and Ruby project generator own the
native setup.

The native build phase exports and verifies the bundle before
copying it into the app.
