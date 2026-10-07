# Private preview Inbox storage

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/private-inbox-storage.md).

[#594](https://github.com/unwired-dev/product/issues/594) adds persistent read
state to the synthetic Inbox in both Apple hosts. Selecting a message leaves its
read state alone. **Mark as read** and **Mark as unread** commit a field update
before publishing the resulting snapshot to the application. Selection stays in
each window or route and is never persisted.

## Failure behavior

The complete fixture, including metadata and bodies, remains encrypted on the
device. This small fixture store is not a general mail database, and it is separate
from the Gmail [message body cache](#message-body-cache). Temporary writes contain
ciphertext, not fixture plaintext.
The encrypted store is excluded from backup; iOS writes use complete file protection.
Its encryption key is device-only, never synchronized and accessible only while
unlocked. Locked data stays inaccessible without replacing stored ciphertext.

JavaScript can open the store and set one message's unread field. It cannot
create, read, replace, or remove the encryption key.

Lock-time I/O failures are reported as locked so retry
can recover after unlock without replacing ciphertext. Only unavailable protected
data is locked: a missing or malformed key, or any other Keychain failure, is
reported as unavailable because unlocking cannot recover it.

Opening an existing file requires its existing key. Missing, inaccessible or
malformed keys do not generate replacements. Authentication, decoding, version,
and file-access failures preserve the stored bytes. The interface hides stale
mail, reports locked or unavailable storage, and offers **Try again**. Returning
to the foreground also reloads storage. Retry neither resets storage nor recovers
a permanently lost key. There is no reset or key-export API in the app.

Independent windows or native store instances cannot
overwrite completed changes using an older snapshot. An error never falls back to an in-memory Inbox.

The synthetic credential fixture creates, uses and removes a random secret only
in native code, independently of the database key. It has no JavaScript secret getter, network client,
logging, or Convex integration. Removing it leaves the database key intact. It
is an integration fixture, not Gmail authorization or a production token API.

## Gmail mailbox cache

The [connected Gmail Inbox](gmail-inbox.md) persists its messages and synchronization
checkpoint atomically in an encrypted device-only cache. Its keys stay native,
its files stay out of backups, and locked or unreadable storage exposes no mail.
A missing key for existing encrypted data is an error, never a replacement key.

Each [Mailbox Connection](gmail-inbox.md#gmail-mailboxes) has its own cache, in a
directory named by the connection's opaque ID, for its address and the Google account
behind it. Cache access adds no Google account identity field to the bridge. Opening a
connection's cache for another address or Google account reads as empty, and each
commit replaces only the revision its caller read. JavaScript reaches it only through
the registration module, which checks that the named connection exists, that its
address matches and that no account removal is under way; an ID that is not a
connection ID never names a path. Removing a connection removes its directory.
Every account purge removes every connection's cache before any key, and a failed
removal fails the purge so it is retried. A connection removal clears its credential
before cache cleanup; failed cleanup retains a retry and keeps that connection closed. Removal needs no key, so it also runs while
the device is locked. A cache written before Mailbox Connections moves, with its
bodies, into the directory of the connection whose address and Google account it
belongs to, so its saved changes survive. Removing the legacy connection before
opening its Inbox also removes its earlier cache and bodies, without needing their
key. Removing another connection preserves that legacy connection's pending changes.

## Message body cache

Opened and prefetched [Gmail message bodies](gmail-inbox.md#reading-messages) are kept in the
**Bounded Encrypted Body Cache**, also excluded from backups. Bodies are bound to
their Google account, mailbox and message, so a saved body moved to another
message or mailbox fails to open. A damaged or mismatched body reads as absent and is removed only when writes
are authorized. Cache-only reads preserve files and access times. Opening is
permitted in the cache-only offline mode; saving
and pruning need a verified mailbox. Every call carries the connection and its
generation, so work started before that connection was removed or verified again
reaches nothing. Body-cache work keeps the interface
responsive. A lock or mailbox change during a read prevents its result from being shown.
Saving a body reserves space
within the 500 MB budget before it is published. It removes opened bodies before
prefetched ones, least recently read first, and never removes a body in the
current recent working set. A body that cannot fit that way is refused and stays
on demand, as is one larger than the entire budget. Pruning reconciles any
over-budget cache left by an older interrupted writer. As in admission, only the
recent working set's bodies that fit within the budget, in working-set order, stay
protected; the limit always holds. The 500 MB budget is device-wide: bodies of every
connection, and bodies saved before Mailbox Connections until they are adopted or
removed, count toward it and may be evicted for another connection's body outside
that connection's working set, while pruning removes only its own connection's
bodies. Removing a connection, and every account purge, remove the bodies with the
mailbox cache.

## Native wiring and signing

The Expo config plugin copies the native sources into its generated iOS project.
Regenerate and reinstall Pods after native source changes. Simulator builds must
retain ad-hoc signing so Keychain receives an application identity;
`CODE_SIGNING_ALLOWED=NO` builds cannot exercise storage. The Mac project
generator compiles the same native sources directly. Neither mechanism autolinks
another host's renderer.

Mac Data Protection Keychain access requires development or distribution signing
with an application identifier, Keychain access group, and matching provisioning
profile. Ad-hoc builds can compile but cannot qualify persistent storage; they
report unavailable storage when Keychain access is denied. Supply your configured
Unwired signing identity and team, with the matching Mac development profile
already installed:

```sh
UNWIRED_SIGNING_IDENTITY='Apple Development' \
UNWIRED_DEVELOPMENT_TEAM='<your team>' \
mise exec -- pnpm --filter @private-email/macos native:build Testing
```

The project does not enable provisioning updates or create developer-portal
resources automatically. Distribution signing remains a release qualification
requirement.

## Verification

Deterministic shared and component tests use `makeMockInboxStorage` only at the
native boundary. [Native Mock Mail Sessions](mock-mail-sessions.md) use the real
encrypted store and a disposable app/Keychain namespace. Shared
and component tests exercise application state, retry, malformed responses,
window selection and read changes. They do not prove encryption or process
persistence. Run their lint, format, type and test checks through the root workspace.

The app-hosted Swift Testing suite uses the real filesystem, CryptoKit and
Keychain. It checks reopening, ciphertext without fixture plaintext, rejection
with a wrong or missing key, preserved corrupt data, credential use/removal,
credential/database isolation and competing native store instances. A controlled
protected-data availability boundary also checks locked first-run access, preservation
of existing ciphertext and keys, and recovery after unlock; physical-device lock
qualification remains separate:

```sh
mise exec -- zsh native/private-inbox/integration/test.zsh ios
UNWIRED_SIGNING_IDENTITY='Apple Development' \
UNWIRED_DEVELOPMENT_TEAM='<your team>' \
mise exec -- zsh native/private-inbox/integration/test.zsh macos
```

The Mac probe also requires a profile for `dev.unwired.storage-probe.StorageHost`.
Its host runs in the App Sandbox, so the real filesystem and Keychain contracts
exercise the same sandbox boundary as the Mac application.
A plain `swift test` runner has no application Keychain entitlement; use the
hosted suite. The iOS runner owns a fresh iOS 27 Simulator, retries recognized
infrastructure failure or zero-test success once, rejects test failures, and
cleans up its Simulator and build directory. Results remain under
`artifacts/private-inbox/`. The Mobile CI native job runs this suite and uploads
its evidence.

The existing mobile XCTest journey now marks a message read, terminates the app,
relaunches the packaged binary and verifies the restored read state on iPhone and
iPad. The Mac journey checks cross-window read updates and persistence after
explicit Quit and relaunch, alongside its existing lifecycle assertions. These
journeys exercise the native bridge and process boundary. Follow the existing
[mobile](expo-client.md#validate) and [Mac](macos-client.md#verification) runners.

Simulator and development-signing evidence does not establish physical-device
lock/unlock behavior, backup/restore behavior, or distribution entitlement
correctness. Those remain release checks. See the
[qualification record](qualification/expo-react-native-client.md).
