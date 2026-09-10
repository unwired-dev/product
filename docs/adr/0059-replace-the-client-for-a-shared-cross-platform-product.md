---
status: accepted
---

# Replace the client for a shared cross-platform product

The replacement client will use Expo and React Native to improve development
speed, user experience, and the ability to add Android and Windows later. Replace
the existing client implementation, including its mail engines, rather than
wrapping the current Swift client. Use Expo for iPhone and iPad and a separate
React Native macOS host, sharing TypeScript application code. Write new native
modules where system integration requires them. Package versions and individual
native dependencies still require qualification. The first implementation
milestone covers Mac menus, shortcuts, multiple windows, background operation,
and automated testing. The maintainer confirmed the design and authorized
implementation to proceed while version-27 native validation is unavailable.
Record those checks as deferred, never as passing; retain them for release
qualification without lowering the deployment floors.

Retain Convex as the backend technology. Rebuild authentication and change backend
contracts where the replacement requires it; retaining Convex does not require
preserving Apple-only identity assumptions. This keeps the existing backend
platform while avoiding an unrelated technology migration.

The first release targets iOS 27, iPadOS 27, and macOS 27 or newer. Mac support
includes desktop menus, keyboard shortcuts, multiple windows, and background
operation. Android and Windows are future targets, not first-release commitments.
The product has no existing users, so the replacement may start with fresh local
and backend data where necessary. It does not need compatibility migrations for
the current prototype. This permits a simpler replacement at the cost of
discarding existing implementation work; it does not require deleting development
data during the design interview.

Gmail is the only first-release Mail Provider. IMAP/SMTP and Microsoft 365 follow
later; this decision commits to no delivery order between them and no legacy
provider support. It replaces the broader rollout order in
[ADR 0011](0011-provider-native-mail-adapters.md) for the new client. Provider
capability boundaries remain useful, but their implementation is being replaced.

Google and Apple are the first-release Sign-In Providers. Google registration
also requests Gmail authorization; Apple registration continues directly into
Google authorization to connect a Gmail mailbox. Microsoft sign-in follows later.
Product Account registration connects the mailbox only after the user grants the
required permission. Interrupted or declined Gmail authorization leaves a
resumable setup flow. Explicitly verified linking can make Apple and Google
alternate sign-ins without merging accounts by email. See
[ADR 0061](0061-separate-product-identity-from-registration-mailbox-authorization.md).

Preserve End-to-End Encrypted Product Sync, device-local mailbox credentials, and
the prohibition on backend-readable mail content. A new device obtains its own
Gmail authorization and obtains Product Sync keys through existing-device approval
or a Recovery Key. Product Account sign-in supplies neither the mailbox grant nor
the decryption keys by itself. Clearing the current unused development database
is a one-time cutover step, not a replacement for production enrollment or recovery.

Preserve explicit, on-device-only Mail Assistance and useful mail functionality
when AI is unavailable. The version 27 deployment floor replaces the version 26
floor in [ADR 0052](0052-keep-mail-assistance-on-device-and-input-bound.md) for the
replacement; it does not replace that decision's privacy and availability
requirements. Launch assistance includes on-device summaries, rewriting, reply
assistance, and translation, each explicitly invoked and usable only when its
required system capability is available.

The first release is a focused Gmail product, not full parity with the prototype.
It includes multiple Gmail accounts, a unified inbox, reading and search,
attachments, drafts and replies, sending, an offline cache, a reliable Outbox,
notifications, and the assistance capabilities above. Advanced profiles,
automation, scheduled sending, and contact/calendar extraction are deferred.
Deferring those features avoids rebuilding their implementation before the core
mail experience is complete. Their prototype documentation is historical input,
not an implicit first-release requirement.

Local message lists are immediately usable. Recent message bodies use an encrypted
cache limited to 500 MB per device, and attachments download on demand. Clearly
distinguish cached messages from messages requiring connectivity. Sender and
subject search works offline; Gmail full-text search requires connectivity.

Rich-text Drafts and their assets synchronize end-to-end encrypted, preserving
conflicting edits as separate copies. The device where the user presses Send owns
the resulting queued delivery. Use a default 10-second Undo Send window and never
automatically resubmit a message with an uncertain delivery outcome. See
[ADR 0062](0062-keep-queued-delivery-on-its-originating-device.md).

After the user grants notification permission, notify for new Inbox messages,
with per-connection switches. Generic notifications are the default; sender and
subject previews are opt-in. Historical synchronization never generates new-mail
alerts. This replaces category-based eligibility for the focused release; see
[ADR 0063](0063-notify-for-new-inbox-mail-without-categorization.md).

Closing the last Mac window leaves the app running and synchronizing. Explicit
Quit stops synchronization and queued delivery until the app reopens. A separate
background helper is deferred. iPhone and iPad background execution remains best
effort, consistent with device-local provider credentials.

Distribute beta builds through TestFlight, then release through the App Store on
iPhone/iPad and the Mac App Store. Defer direct Mac distribution and its separate
update pipeline. The native Mac host needs its own archive and submission path.

Convex is a required service for send admission. Use a content-free atomic claim
before Gmail submission to coordinate competing attempts to send the same Draft.
There is no separate Convex-outage mode or alternate sending path in the first
release; ordinary unsuccessful operations remain queued or report their error.

The product-scope interview and shared-understanding confirmation are complete.
The implementation begins with platform
qualification, then identity and private storage, the Gmail Core Mail Loop,
assistance and notifications, and the development cutover. Package compatibility,
native integration, and runtime behavior still need proof. See the
[rewrite research](../research/expo-react-native-rewrite.md) for the evidence,
implementation gates, and verification targets. Use
[separately installed native hosts](0064-isolate-mobile-and-macos-native-dependencies.md);
the [platform qualification record](../qualification/expo-react-native-client.md)
distinguishes completed dependency and bundling checks from deferred native checks.
