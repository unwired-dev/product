---
status: accepted
---

# Isolate mobile and macOS native dependencies

The Expo mobile host and the React Native macOS host have different supported
React Native and React renderer versions. Keep their installations independent
while sharing framework-independent TypeScript application logic.

The initial pins are Expo 57.0.21, React Native 0.86.3, and React 19.2.3 for
iPhone/iPad; React Native macOS 0.81.9, React Native 0.81.6, and React 19.1.4
for Mac. These exact installations passed strict peer checks, and each bundled
the same TypeScript fixture through its own Metro configuration. This establishes
JavaScript dependency feasibility, not native compatibility. The
[qualification record](../qualification/expo-react-native-client.md) contains
the commands, evidence, and remaining checks.

Give each host its own package root, workspace boundary, lockfile, native
autolinking scope, and Metro resolver. Continue using pnpm 11.5.2. Do not put
both React Native graphs into the existing backend workspace or a shared native
dependency catalog. Share application logic through a package without React,
React Native, Expo, or native-module imports. Each host owns its React views and
platform adapters. Sharing React UI can be reconsidered when both host graphs
can demonstrate compatibility; it is not a prerequisite for the rewrite.

An older shared line was considered: Expo 54.0.37 with React Native 0.81.6,
React Native macOS 0.81.9, and React 19.1.4. It departs from Expo 54's recommended
React Native 0.81.5 and React 19.1.0. Using the older macOS package that peers on
0.81.5 does not resolve the renderer-version mismatch. Reject the shared-line
override in favor of the separately checked host installations.

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
iOS, iPadOS, and macOS deployment targets at 27 or newer. Native build, packaging,
persistence, credential, lifecycle, and E2E evidence remains deferred until the
required toolchain and runtimes are available; the exception is not a passing
result and does not waive release qualification or available TypeScript checks.
