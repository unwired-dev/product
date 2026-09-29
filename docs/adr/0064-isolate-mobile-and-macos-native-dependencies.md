---
status: accepted
---

# Isolate mobile and macOS native dependencies

Amended on 2026-09-28 at the maintainer's request: use one root pnpm workspace
and lockfile with named catalogs. This supersedes the original requirement for
independent workspace roots and lockfiles, while retaining native renderer
compatibility boundaries.

The Expo mobile host and the React Native macOS host have different supported
React Native and React renderer versions. The default catalog owns shared tooling
and Effect; `catalogs.mobile` owns the Expo-compatible renderer and native packages.
Add a separate Mac catalog when its actual host is implemented and qualified.
Do not force both hosts onto one renderer version. Continue using pnpm 11.5.2.

The mobile bootstrap uses Expo 57.0.25, React Native 0.86.3 and React 19.2.3.
The earlier independent-installation probe used Expo 57.0.21 for mobile and
React Native macOS 0.81.9, React Native 0.81.6 and React 19.1.4 for Mac. Its
[qualification record](../qualification/expo-react-native-client.md) is historical;
it does not establish that a future Mac host can share the current installation.

Catalogs are version constants, not runtime isolation. Each host's Metro bundle
and native autolinking must resolve exactly its compatible renderer/native graph.
The current mobile mock Inbox passes strict peer installation, production bundle
inventory, and local iOS/iPadOS 27 simulator Release build, launch and interaction
checks using the root workspace. This does not qualify real provider, persistence,
credential or full-product behavior. Mac resolution and autolinking must be
qualified when that host is added.

Share application logic through `workspace:*` packages without React, React
Native, Expo or native-module imports. Each host owns its React views and platform
adapters. Sharing React UI can be reconsidered when both host graphs demonstrate
compatibility; it is not a prerequisite for the rewrite.

An older shared line was considered: Expo 54.0.37 with React Native 0.81.6,
React Native macOS 0.81.9, and React 19.1.4. It departs from Expo 54's recommended
React Native 0.81.5 and React 19.1.0. Using the older macOS package that peers on
0.81.5 does not resolve the renderer-version mismatch. Reject the shared-line
override; named catalogs preserve the separately selected supported versions.

Keep AppKit in charge of Mac windows, menu commands, focused-window routing, and
application lifetime. Windows have stable identities and independent selection;
closing the last window keeps the application running, while Quit terminates it.
Native storage owns device-local Keychain policy and database encryption keys.
The shared application code must not coordinate database-key generation or receive
database encryption keys merely to open storage. Qualify the concrete native
storage implementation separately before treating its privacy properties as proven.

This trades duplicate host view code and separate native build setup for smaller
upgrade and compatibility boundaries. It preserves reusable mail behavior and
future Android/Windows options without forcing either current host onto the
other's renderer line.

On 2026-09-09 the maintainer authorized implementation to continue without native
version-27 validation because no suitable Mac is available to the project. Keep
iOS, iPadOS, and macOS deployment targets at 27 or newer. The 2026-09-28 mock Inbox evidence above supersedes that deferral for its local
mobile simulator build and interaction checks. Remaining Mac-host and full-product
native qualification stays deferred where tooling or implementation is unavailable;
the exception is not a passing result and does not waive release qualification
or available TypeScript checks.
