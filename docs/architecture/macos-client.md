# Macos client: architecture notes

Reviewer-only companion to [docs/macos-client.md](../macos-client.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Host ownership

Apply the [native component selection policy](../agents/native-components.md)
to new UI and migrations. The custom views described below record the current
implementation, not requirements to retain them; AppKit ownership and the Mac
dependency boundary remain in force.

The `macos` catalog pins React Native macOS 0.81.9, React Native 0.81.6 and React
19.1.4 in the root workspace and lockfile. This follows the amended
[ADR 0064](../adr/0064-isolate-mobile-and-macos-native-dependencies.md), which
supersedes the issue's original separate-lockfile requirement. Mac views and
native adapters live in `apps/macos`; `mail-core` imports no UI framework.

Metro redirects React and React Native imports, including subpaths, to this
host's packages. Its startup module also comes from React Native macOS. The
production bundle verification rejects the mobile renderer, Expo, React DOM and
backend code, checks the shared fixture against disk, and verifies native
autolinking. The host admits `@react-native-clipboard/clipboard` for Copy link and
`react-native-webview` for the isolated message reader. Adding another requires
an explicit update to `apps/macos/scripts/verify-native.ts`.

AppKit owns stable window identities and menu routing. One React factory and one
JavaScript mailbox runtime live for the application process. Each window mounts
its own React root and owns its selected message. Closing a window releases its
view; opening another starts with no selection. AppKit separately owns one
`settings-window` surface in the same runtime, without counting or guarding it as
an Inbox window. Its gate retires targeted navigation with its Product Account
and keeps registration activation and assistance loading alive when every Inbox
window is closed. Reading leaves unread flags unchanged. Explicit read/unread actions persist
and update all windows without changing their selections.

## Build and run

The checked-in Objective-C++ host, Podfile and Ruby project generator own the
native setup.

The Mac Podfile loads `scripts/cocoapods-paths.rb` to bypass CocoaPods 1.17.0's
intermittent pnpm base-path resolution failure. The workaround keeps the group's
base path lexical; CocoaPods still resolves source file references and creates
localized resource variant groups. The upstream-derived grouping method and its
license remain together in the Mac scripts directory.

The generator also compiles the first-party SF Symbol and Liquid Glass view
managers from `native/design`. Host components consume them through Fabric's
legacy-view interop. This adds no autolinked package and preserves the existing
third-party module allowlist. Native visual and accessibility qualification is
separate from compilation and JavaScript bundle verification.

Link confirmations belong to the window above its sidebar and both columns,
while its selected mailbox store and message retain presentation ownership.
The first-party `UnwiredModalBackground` view suppresses the covered accessibility
subtree in AppKit because React Native macOS omits its core modal accessibility
properties.

The native build phase exports and verifies the bundle before
copying it into the app.

## Isolated categorization research

Issue #831 authorizes an isolated, build-time `categorization-spike` Mock Mail
Session, with public/synthetic bundled samples and no mailbox assignments or
production adoption. The Mac-local `categorization-spike-client.ts` adapter owns
Schema decoding for native payloads; the React page owns only this research
interaction's request and presentation state. This narrowly qualifies the normal
shared-store ownership rule for this one Mac-specific research build. Future
product integration follows the normal mail-core store rules and needs its own
qualification. Bundle verification excludes both page and adapter from every
other scenario and production.

The OCR decision panel on 2026-10-15 considered A, a non-React Mac-local research
adapter with local presentation state, and B, a testing-only mail-core store
owning decoding and requests. Claude Fable 5.1, GPT-6.1-Sol and GPT-6-Astra all
chose A, because there is no shared product behavior to own and adding a shared
experimental API would broaden the spike. All required decoding and production
isolation remain enforced. No earlier model/runtime or visual-design decision
changed.
