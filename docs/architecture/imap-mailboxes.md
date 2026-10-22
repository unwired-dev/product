# IMAP mailbox implementation and qualification

Reviewer-only companion to [IMAP mailboxes](../imap-mailboxes.md), introduced by
[#629](https://github.com/unwired-dev/product/issues/629). Operational requirements
and validation commands remain there. Prototype SwiftMail qualification does not
qualify these replacement hosts or this adapter.

## Library evaluation and decision

The existing decision panel selected SwiftMail 1.16.0 behind a native adapter with
TypeScript synchronization policy/cache (2–1), a separate reduced IMAP reader
(3–0), and provider choice before a first mailbox grant (3–0). These decisions
preserve Product Sign-In independently of IMAP credentials and Gmail consent.

| Candidate                                                    | Host fit and evidence                                                                                                                                                                                                                                                      | Disposition                                  |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| [SwiftMail](https://github.com/Cocoanetics/SwiftMail) 1.16.0 | Swift package on Apple's swift-nio-imap, supports the Apple deployment targets; implicit verified TLS, read-only selection, UID fetches and parser limits are available in the pinned source. The real adapter compiles in both Expo iOS and React Native Mac host graphs. | Selected; adapter evidence below.            |
| [ImapFlow](https://github.com/postalsys/imapflow)            | Its documented runtime is Node.js (also Bun and Workers with Node compatibility). A direct use in Hermes would require a socket/TLS and Node compatibility binding; that host-fit conclusion is an inference from its runtime contract.                                    | No qualified host binding; not selected.     |
| [MailCore 2](https://github.com/MailCore/mailcore2)          | Objective-C/C++ Apple IMAP library, with a separate native integration graph. No replacement Expo/Mac graph or lifecycle proof was built in this slice.                                                                                                                    | Native candidate, not qualified or selected. |

This comparison records static candidate assessment separately from compiled and
executed qualification. No rejected candidate is claimed to have been built on
these hosts. SwiftMail and swift-log direct revisions are pinned in the native
manifest; Package.resolved fixes the transitive graph. Expo, Mac and hosted storage
project generators read those products/revisions. Incremental Expo prebuild updates
existing URL pins and restores app product and Frameworks references idempotently.

## Ownership and transport

The folder listing runs in TypeScript over a short-lived native session handle
(#1177). Native `SwiftMailImapSession` exposes capabilities and complete LIST
results with attributes; TypeScript assigns roles, normalizes ASCII INBOX names
and derives MOVE, UIDPLUS and IDLE support. `RegistrationStore` binds each handle
to its connection, address, generation and receipt subject, admits one command
at a time, and owns expiry, limits and invalidation cleanup. TypeScript's
`acquireUseRelease` closes the handle on success and failure. The operational
[IMAP guide](../imap-mailboxes.md#engine-and-dependencies) owns the limits and
observable close contract.

Closing removes the handle and answers its in-flight caller once with
`mailbox-invalidated`; the command's later result cannot resume that caller.
SwiftMail 1.16.0 queues `disconnect()` behind an active command, whose NIO response
wait does not observe task cancellation. The connection therefore closes only
when that command answers or times out. Wire-level abort remains #1184, and the
TypeScript interruption test remains with the first interruptible caller, IDLE
(#1181).

The remaining operations still open one authenticated session each through
`SwiftMailImap`, perform `EXAMINE` for reads and `SELECT` for explicit mutations,
use `BODY.PEEK` and close success and failure paths. TLS starts before
authentication, uses full certificate verification and requires TLS 1.2 or newer.
No plaintext/STARTTLS fallback or production trust override exists. The parser
rejects body literals over 40 MB before buffering payload, and bounds response
attributes independently of the untrusted RFC822.SIZE claim. SwiftMail logging is
bootstrapped to a no-op because upstream logs can contain endpoints, folder names
and server replies.

Native registration retains the password in the device Keychain and validates
the reviewed endpoint. Generation/verification fences refuse late work from a
replaced connection/account. The bridge projects only non-secret connection
metadata. Gmail refresh, requests and watch/stop/due routing reject IMAP connections
before using their credentials. The package-free metadata check gets an unavailable
engine stub; production host builds link the manifest's real SwiftMail product.

## Cache, identity and presentation

TypeScript's separate IMAP store owns folder selection, the 200-message window,
UIDVALIDITY/UIDNEXT/cached UID checkpoints, cache commits and incremental resumption.
Native transport fetches current flags and new envelopes; a UIDVALIDITY change
invalidates prior message identity. Inbox plus eight other folders are retained in
the encrypted metadata cache. Bodies use the existing bounded encrypted body cache.
Folder retirement uses a complete namespace-aware listing. Oversized results and
failed advertised namespace discovery refuse the refresh rather than present
partial results as absence. TypeScript commits the listing and retained mailbox
metadata before dropping retired views; commit refusal preserves the previous
listing and evicted-folder rows. Still-selectable evicted views continue to
protect their saved bodies.
MIME parsing feeds the shared sanitizer, with positional capture extraction for
native runtimes and bounded depth/parts. IMAP reader owners
use the same display allocation coordinator as Gmail, charging repeated images and
simultaneous windows, releasing allocations on reader cleanup and rich-body failure.

Issue #1019 adds Remote Message Content through the shared loader. The host resolves
the device policy and connection override before authorizing the loader, as for Gmail.
The connection-bound native operations use the existing Authorized Remote Content
Cache; message IDs include folder, UIDVALIDITY and UID, so a new identity cannot reuse
the old identity's authorization. Still-shown old rows remain readable until their
view is replaced. Loaded remote images share the display budget with inline images
and other readers. Last-reader closure, Inbox closure and access-closing failures
release remote work; a failed rich presentation withdraws that reader's interest.

Issue #1020 reuses Gmail's attachment download lifecycle and native storage/presenters.
Descriptors come from the parsed message source; explicit downloads reread that source
at the message's UIDVALIDITY and revalidate the descriptor before saving its bytes.
Successful cache adoption of a new UIDVALIDITY retires the folder's saved attachments
and fences pending downloads, including readers retained after the folder's metadata
checkpoint was evicted. Late body replies reconcile their descriptors against that
committed identity too. Search replies, refused source reads and failed cache commits
do not retire other attachments before a later successful synchronization adopts the
new identity; a refused source read still reports its own attachment as missing.
The native `imapMessage` task has no cancellation handle. Cancel and last-reader
cleanup remove download ownership immediately, but `sourceOf` keeps its native
call uninterruptible until settlement. `explicitLoad` therefore holds the
connection and device permits and interactive ownership for the actual transfer;
cancelled results cannot retain a saved attachment or restore its row. Ending the
native transfer itself remains [#1172](https://github.com/unwired-dev/product/issues/1172).
The [operational guide](../imap-mailboxes.md#reading) owns limits, actions and cleanup.
Prefetch and reader responses remain follow-up work under #882.

Private Sync descriptors carry `provider: imap`. The native receipt's subject is
`host:port:username`; its provider-scoped account, `imap:host:port:username`, supplies
the connection identity and descriptor key under the shared provider scheme.
Existing Gmail keys remain unchanged. The
password is device-local; another Trusted Device lists only the synchronized
address and connects it through fresh provider/endpoint/password setup. No remote
descriptor creates a local placeholder connection or a password-repair route.
`getConnections` combines providers for Inbox; the existing `getSnapshot` retains
Gmail and Microsoft connections for its consumers, whose Gmail-only capabilities
remain filtered at their own boundaries. IMAP authorization notices route to
password repair, including a refused connection whose saved registration still says
connected, and never to Gmail consent.

After a successful decoded `connectImap` result, the flow carries its receipt's
connection ID in action-only `imapConnected` metadata. The store decodes it, checks
connected membership, removes it from the host snapshot and publishes the ID as
repair metadata. This identifies the authenticated connection even when iCloud's
name-part attempt fell back to its full address. Legacy snapshot-only native
adapters still match the reviewed endpoint. `createMailboxes` reconciles
owners first, then reloads that connection's Inbox if it was retained across the
change, whatever its status, to reopen its native generation. A newly opened or
owner-replaced Inbox follows its normal initial load. Snapshot identity alone
never dispatches repair reads.

## Organizing, search and freshness

[#630](https://github.com/unwired-dev/product/issues/630) adds organization without
changing credential custody or the reduced reader. Special-use role
actions require exactly one selectable destination; ordinary Move to remains an
explicit folder choice. A pending role action is refused when a refreshed listing
changes its meaning or makes it ambiguous.

The encrypted IMAP document retains an ordered pending queue. Dispatch of a move
is committed before its native call. A move whose outcome is unknown and has no
destination mapping blocks later actions until explicit discard; source absence
alone cannot prove the destination. Read-flag mutations remain idempotent.

Without MOVE, native transport returns a verified COPYUID after COPY alone.
TypeScript commits that continuation before requesting source deletion. The next
native request checks the destination generation and copied UID, then the source
generation, and sends STORE Deleted and targeted UID EXPUNGE. Replays of this
continuation never COPY again. An unavailable or invalid COPYUID prevents source
deletion and automatic replay. MOVE partial-completion failures remain uncertain.
Settled actions update cached and still-shown folder snapshots together.

The existing #630 panel chose all selectable folders except Trash/Junk for online
search over only the viewed folder, by three votes to zero. Inbox comes first,
then special-use folders and the remaining folders; the request caps at 50 folders
and returns the newest 50 matches per folder with truncation disclosure.

Each watched connection uses IDLE only when advertised. Its failed waits reconnect
with a five-second-to-five-minute backoff, alongside the active-app five-minute
poll and foreground catch-up. The Mac application owns its watchers; mobile
foreground ownership stops future waits outside active state. Search and bounded
IDLE release the global registration gate during network waits, retaining native
credential and generation checks before and after the operation.

## SMTP submission and Sent filing (#631)

`SwiftMailSmtp` uses the pinned SwiftMail engine with mandatory implicit TLS or
STARTTLS, full certificate verification and a TLS 1.2 minimum. Registration
verifies IMAP and SMTP independently before saving either endpoint's grant.
Optional separate SMTP credentials stay in the same device-local Keychain record;
projections carry only the endpoints. Repair retains the connection identity and
renews its generation. Older records without SMTP remain receive only until repair.

The #631 decision panel chose to require one unique selectable server-declared
Sent folder, 3–0; allow a separate SMTP password for manual servers, 2–1; expose
SSL/TLS versus STARTTLS with port-based defaults until explicitly chosen, 2–1;
and upgrade existing receive-only connections only after password re-entry and
SMTP verification, 3–0. These outcomes preserve the originating-device Outbox
and required atomic Convex admission in ADR 0062 across providers.

The shared Inbox removes the Bcc header and continuations from the frozen MIME
segments only for submission. The native adapter assembles those segments with
verified asset bytes, uses the connection address as the SMTP envelope sender,
and includes To, Cc and Bcc envelope recipients. The Sent copy keeps the original
segments, including Bcc and the generated Message-ID.
SwiftMail's submission-phase retry disposition distinguishes definite refusal
from possible acceptance; unsafe-to-retry errors remain delivery unknown.

SMTP acceptance advances the durable Outbox to `filing` before APPEND. Only
filing retries thereafter. Native Sent filing checks current Trusted Device
revocation proof and connection generation, searches the selected folder's
Content-Type for the frozen MIME boundary, and appends with Seen only when no
copy is found. A lost APPEND reply retries the lookup without SMTP resubmission.
Unknown SMTP outcomes use the same boundary lookup, confirming only exactly one
copy and never inferring non-delivery from absence. Native lookup uses IMAP HEADER
substring matching; live preservation and server-created Sent copies still need
provider qualification. Access-changing lookup/filing failures close or refresh
the owning shared mailbox presentation, with late replies fenced by its lifetime.

## Evidence and release limits

The implementation handoff recorded Swift package build/tests, plaintext refusal,
both host native builds, native graph gates and a hosted iOS storage run at the
pinned implementation head. Reviewer validation adds the real SwiftMail TLS
protocol fixture to the hosted iOS suite. The runner creates a synthetic root and
localhost certificate, trusts that root only on its owned disposable simulator,
and owns the fixture port and cleanup. It checks authentication refusal,
read-only selection, folders, UID envelope/flag reads, body retrieval, UIDVALIDITY
refusal, oversized literal declaration and session closure. It does not prove
the complete rendered IMAP setup/read/relaunch path or real provider compatibility.

Shared controlled-provider tests exercise the actual TypeScript store and cache
contracts; those fixtures implement bridge replies rather than TLS/IMAP. App
registration journeys exercise immediate password repair on both host components.
Native Mock Mail Sessions still reject IMAP connection attempts.

Real iCloud/Fastmail reads require accounts and remain release work in #632. Native
Mac controlled-TLS reads, complete native IMAP setup/open/relaunch journeys and
power-user parity remain explicitly unqualified. Connections saved before #631
remain receive only until SMTP is verified; the reduced reader remains in scope.

The #630 controlled TLS suite also exercises read/unread STORE, MOVE/COPYUID,
two-phase UIDPLUS fallback, replay with an absent source, destination-generation
and copied-message refusal, unmapped and interrupted COPY without source deletion,
tagged move refusal, lost MOVE reply, cross-folder search, bounded IDLE and a
compressed ESEARCH range spanning four billion UIDs without expanding that range. Its
wire fixture is controlled protocol evidence, not live-provider or full host
interaction qualification. Shared regressions cover durable continuation recovery,
unknown outcomes and external deletion, ambiguous/changed roles, settled folder
views and IDLE recovery. Host component journeys cover visible uncertain-move
discard without replay.

The #630 reviewer could not complete a fresh Mac host build: both scripted attempts
failed during CocoaPods generation with `ArgumentError: pathname contains null byte`.
A direct build of the generated workspace then lacked React and GoogleSignIn module
dependencies. This is unavailable final-tree Mac host evidence; earlier host builds
do not qualify the changed bridge. Native package and hosted iOS adapter evidence
remain separate from that requirement.

The #631 handoff records a hosted iOS suite with 53 tests, including real
SwiftMail implicit-TLS/STARTTLS submission and refused/uncertain outcomes, plus
Sent header search and idempotent APPEND. It also records a successful Testing
Mac host build compiling the SMTP adapter and bridge, superseding #630's
unavailable Mac compile evidence for this tree. Shared sending journeys use
controlled native bridge fixtures rather than wire servers. Real iCloud/Fastmail
SMTP and Sent filing, native Mac controlled TLS and full native sending journeys
on iPhone, iPad and Mac remain required release evidence in #632 and #855.
