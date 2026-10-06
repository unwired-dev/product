# Gmail Inbox: architecture notes

Reviewer-only companion to [the operational guide](../gmail-inbox.md), under the
[implementation and review workflow](../agents/implementation-review.md).
Issue [#604](https://github.com/unwired-dev/product/issues/604) introduces the
replacement Gmail provider adapter. It reuses no prototype Swift mail engine.

## Transport evaluation

Gmail's [REST resources](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list)
and [synchronization protocol](https://developers.google.com/workspace/gmail/api/guides/sync)
use JSON over HTTPS. A separate native Gmail library would duplicate pagination,
history reconciliation and response shapes without adding a needed platform API.
No Node.js SDK is assumed to run in React Native. TypeScript owns the REST paths,
query parameters, Schema decoding, synchronization and classified presentation
state as an Effect program in `packages/mail-core`.

Native code adds value at credential custody. Under
[ADR 0067](../adr/0067-keep-native-code-to-a-minimal-vault.md), provider tokens never
leave native code. One purpose-specific Gmail read accepts only `profile`,
`history`, `messages`, alphanumeric `messages/<id>` paths and
`messages/<id>/attachments/<part>` with alphanumeric, underscore or hyphen part
identifiers below
`https://gmail.googleapis.com/gmail/v1/users/me/`. It renews and attaches the
mailbox credential, preserves repeated query parameters, refuses redirects and
returns only status/body. The ephemeral URL session keeps HTTP response caches
off disk. Native and TypeScript diagnostics use fixed allow-listed values.

The bridge exposes `gmailRequest(path, query, mailbox)`, `openMailbox()` and
`commitMailbox(mailbox, expectedRevision, document)`. The cache reply contains
revision, address, an opaque native generation and an optional document, with `availability: retry` only for
cache-only access. The mailbox argument pairs the opened address and generation. Native errors distinguish grant rejection, protected storage,
revision conflict, mailbox invalidation and ordinary unavailability.

## Synchronization and cache

The first listing captures the profile history ID before reading Inbox pages.
Each page commits its applied messages and a backfill checkpoint containing that
history ID, next page token and seen IDs in one encrypted document. Metadata reads
queue at most four requests; native custody serializes transport with registration.
List pages request 50, and the final cache retains 200
newest messages. This bounded whole-document cache postpones indexed Historical
Metadata Backfill. Message IDs deduplicate replayed work.

Relisting retains cached entries for availability but prioritizes verified list
entries before applying the bound, then discards unseen entries at completion.
A rejected saved page token starts another listing, with bounded restarts.
History applies additions, deletions and label changes, re-fetching changed IDs.
Intermediate pages advance to their last history record; the final page commits
the mailbox history ID. Gmail documents that history IDs increase in
[chronological order](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.history/list).
Expired history relists; losing an entry from a full cache relists to admit an
unchanged older message. An unreadable document fails closed without replacement.

The [native cache companion](private-inbox-storage.md#gmail-mailbox-cache) owns
encryption and compare-and-swap. Shared store operations serialize with a
semaphore, publish only durable commits and restart revision conflicts or native
mailbox invalidations at most twice, reopening the committed cache each time.
Documented Gmail 403 usage-limit reasons, including `dailyLimitExceeded`, retain
the cached list with a retry notice rather than prompting reauthorization.

## Authorization and suspended work

Native mailbox operations and registration changes share a FIFO operation gate
across suspension points. Revocation cleanup cannot interleave with captured
registration writes and resurrect removed credentials. Host foreground loads
await the shared registration activation before accessing Gmail. A generation changes on
restore, successful mailbox authorization and purge. Cache operations validate it after
revocation preflight; Gmail reads validate it before token renewal and after
renewal and provider response, preventing a suspended
operation from using or returning the previous mailbox after cleanup or
reselection. Token renewal itself does not change the generation, so concurrent
metadata reads can refresh without invalidating each other. Revocation preflight runs when opening the cache and before each committed page,
so the backend receives no per-message read activity. A positive device revocation
purges before cache access or commit. Gmail reads perform local account,
verification, address and generation checks without a backend query.
Each read and commit carries the address and opaque native generation returned by
the synchronization's cache open. Reselection between successive operations,
including another Google subject reusing the address after revision reset,
rejects mailbox-invalidated.
An invalidated synchronization reopens through the FIFO gate after the
registration operation, obtaining its renewed generation. Same-mailbox foreground
verification can therefore resume from the committed cache without publishing
`failed`. Persistent invalidation exhausts the bounded restarts and hides the
mail. Ownership changes and purge still clear and fence the in-memory Inbox
immediately; retrying the native open cannot restore access to the former
mailbox. Both hosts filter ready state against the selected mailbox
address before rendering, including the first frame while its cache opens.
The process-owned Gmail store also subscribes to registration: a Product Account,
Google subject or address change, or loss of Inbox eligibility, immediately clears
its in-memory mail and suppresses late publications until the next serialized
synchronization starts. The hosts discard Account/Inbox presentation choices when
the Product Account changes or Inbox eligibility is lost. The shared
`inboxLanding` helper also invalidates an Inbox choice when different pending
setup appears for that same account. A choice records `inboxSetup` at the time
it is made: setup kind markers, the transient enrollment code and the pending
enrollment request ID, without copying the Recovery Key. A renewed enrollment
code therefore differs even while the device remains enrollment-pending. An explicit
Account choice persists, and choosing the Inbox over already-pending setup
remains valid while that setup is unchanged or clears.

Known transient network failures may restore a separate `cached` registration
snapshot for the last verified mailbox with retained account ownership and no
removal or setup failure. It is presentation-only. Native provider reads and
cache commits remain closed until verification succeeds. The shared Gmail store
opens the encrypted cache with a retry notice; retry restores registration first.
OAuth grant refusal, identity/TLS failure, unknown errors, removal and locked
storage do not gain this exception. Product Sign-In and mailbox authorization
remain distinct under [ADR 0061](../adr/0061-separate-product-identity-from-registration-mailbox-authorization.md).

## Message reading

Issue #605 adds `format=full` message reads and separately served body-part
reads through the same native credential and generation boundary. The body
decoder excludes filename-bearing attachments and `message/rfc822` containers,
selects HTML before plain text within the outer message, and checks decoded
bytes against the declared part size. HTML with no readable paragraphs falls
back to a plain alternative. Native cache envelopes fail closed on malformed
shape; an absent or corrupt body document may be downloaded again.

MIME admission examines every repeated header: dispositions must all declare
inline, media-type tokens must agree, and normalized Content-ID values must agree.
CID traversal accepts image leaves and descends only through recognized multipart
containers, keeping ambiguous metadata and non-leaf image parts out of provider reads.

The shared store keeps two body pipelines per current connection and coalesces
duplicate reads. A dedicated publication semaphore orders body admission against
each page's durable metadata commit, body pruning and ready-state publication.
Body admission rechecks owner and list membership under that permit, so a late
body cannot repopulate a pruned message or wait for an entire synchronization.
Provider listing runs outside the publication permit. Completion uses the same
membership fence. Visible readers retain their
body; the twenty-entry memory target evicts only undisplayed completed entries.
Forget clears body state and fences previous-owner completions. Host-local link
confirmations compare their pending mailbox/message with the current render owner
before displaying a destination, subscribe to body invalidation, and bind queued
choices and system handoff to the reader’s committed mailbox/message lifetime
as well as its exact current body presentation, so queued input cannot disclose a previous owner's destination. Selectable link
text has a separate keyboard-focusable control.

The isolated renderer now uses an app-owned `parse5` document and patched
`react-native-webview` on both hosts. Element, attribute, CSS and URL allowlists
strip active content, sender colors and hidden content before discovering CID
references. Remote images remain non-loading placeholders with a notice; remote
consent, policies and the Authorized Remote Content Cache are assigned to
[#763](https://github.com/unwired-dev/product/issues/763), blocked by #605.
Images are admitted from the selected MIME scope only after bounded container
validation. Presentation charges every repeated occurrence against the shared
encoded-byte and decoded-pixel budget, and releases it on close or render failure.
Each reader's opaque token owns its reservation and prepared presentation,
including multiple windows showing the same provider message. Joining a ready
body admits a new presentation against remaining capacity; images that cannot
fit stay placeholders only in the new reader. Established readers keep their
document identity, avoiding navigation and scroll resets. Owner generation fences precede ledger mutation,
and a closing reader from an earlier generation cannot release the current
owner's reservation.
Sanitizer or renderer failure retains the readable-text fallback.

Page JavaScript is disabled on the final `defaultWebpagePreferences` instance,
including after the mobile wrapper replaces that object. The non-persistent
WebKit instance has no base URL or remote-resource permissions and enforces the
app-owned CSP. `originWhitelist={['*']}` prevents the wrapper's automatic system
handoff for unmatched origins; the reader cancels every subsequent navigation
and confirms user links outside WebKit. Anchors carry app-owned stable markers,
so URL normalization cannot strip their visible-text inspection context. Exact
vetted destinations remain in memory outside the document. Keyboard link controls provide the same
confirmation path. Rich content uses the accepted fixed light canvas.

Recent-body prefetch runs in one lane per Inbox, sharing the two-load semaphore
and coalescing an explicit open with an in-flight speculative read of the same
ID. It samples the selection instant once per synchronization, selects an
inclusive 30-day window with newest-first/ascending-ID order and a 500-item cap,
and uses Content-Type and Content-Disposition metadata before any full download.
Only single-part text/plain or text/html messages qualify; multipart and attachment
messages receive exclusion markers. An explicit open closes the interactive
latch; an already active speculative item completes, while later items wait.
Retry, authentication failure and invalidation pause speculation. Native admission
receives tier and protected working-set IDs; refusal keeps an on-demand body.

On 2026-10-06 the product owner accepted bounded all-reference CID loading and
isolated client-world measurement for #605 in the
[ADR 0029 amendment](../adr/0029-sanitize-html-before-webkit-rendering.md#amendment--2026-10-06).
An explicit open resolves every visible, sanitized CID reference within the
existing per-message bounds and shared presentation budget, without a geometric
viewport gate. Recent-body prefetch still never loads Inline Images.
Both hosts measure once after navigation with an application-owned
`callAsyncJavaScript` script in `WKContentWorld.defaultClientWorld`, while page
JavaScript remains disabled on the final preferences object. Invalid measurement
uses retained-text fallback. This supersedes the earlier native-only observation
method; it does not enable sender scripts or an application bridge for message
content. These accepted choices resolve the round-2 B1/B2 requirement conflicts.

The amendments to [ADR 0012](../adr/0012-bounded-encrypted-body-cache.md#amendment--2026-10-06)
and [ADR 0018](../adr/0018-local-mail-performance-budget.md#amendment--2026-10-06)
preserve remote-image viewport loading and all other coordinator, cache and
performance constraints. Remote Message Content remains owned by #763; its
consent, policy, viewport-plus-margin, isolated transport and separate encrypted
cache rules are unchanged and do not authorize retrieval in #605.

## Evidence limits

Controlled transport and cache integration tests, rendered host journeys and
packaged Mock Mail Sessions prove their respective deterministic contracts.
Real Keychain/CryptoKit/file checks qualify the native storage boundaries they
exercise. They do not certify live Gmail authentication or compatibility.
Protected Gmail, physical-device and distribution qualification remains required
under [ADR 0060](../adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md).
