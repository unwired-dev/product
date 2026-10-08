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
`history`, `labels`, `messages`, alphanumeric `messages/<id>` paths and
`messages/<id>/attachments/<part>` with alphanumeric, underscore or hyphen part
identifiers below
`https://gmail.googleapis.com/gmail/v1/users/me/`. It renews and attaches the
mailbox credential, preserves repeated query parameters, refuses redirects and
returns only status/body. The ephemeral URL session keeps HTTP response caches
off disk. Native and TypeScript diagnostics use fixed allow-listed values.

The bridge exposes `gmailRequest(path, query, mailbox)`, `gmailModify(change, mailbox)`, `openMailbox(connection)` and
`commitMailbox(mailbox, expectedRevision, document)`. The cache reply contains
revision, address, an opaque native generation, a non-secret owner identity and an optional document, with `availability: retry` only for
cache-only access. The mailbox argument names the connection and pairs the opened address and generation. Native errors distinguish grant rejection, protected storage,
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
encryption and compare-and-swap. The sync loop and action intake each serialize with a semaphore; compare-and-swap
rejects a stale sync commit after independent intake. Publications reject older
revisions for the same scope. Intake distinguishes unsaved optimism from durable
pending state and restarts revision conflicts or native
mailbox invalidations at most twice, reopening the committed cache each time.
Synchronization and action commits rebase revision conflicts at most twice per
commit, retaining only intake IDs absent from their prior base document. Comparing
with the next document would reintroduce a head just settled by Gmail. Each rebase
requires the same mailbox owner and an existing decoded document; it retains the
operation's checkpoint and provider result while appending newer intents in order.
Known intake IDs missing from the latest document are removed from the proposed
queue because another store instance already settled them. Dispatch checks the
prepared head and its unique attempt ID again before sending. A newer attempt,
refusal or Retry in the saved document takes precedence over stale preparation
or settlement, including when the proposed settlement removed that head.
Store instances in one host process share the set of live attempt IDs, held
from preparation through provider completion and settlement and released by an
Effect finalizer on every outcome. A joining instance leaves a live head pending
without reconciling, dispatching, retrying or discarding it. A completed failure
is immediately eligible for reconciliation/retry; process relaunch clears live
ownership and reconciles saved attempts normally. This avoids wall-clock leases
and has the existing one-host-process scope; competing processes would require
durable ownership and completion fencing. Refusal reconciliation also checks its head
after saving the marker, so a removed action cannot consume the next intent.
Documented Gmail 403 usage-limit reasons, including `dailyLimitExceeded`, retain
the cached list with a retry notice rather than prompting reauthorization.

## Authorization and suspended work

Native mailbox operations and registration changes share a FIFO operation gate
across suspension points. Revocation cleanup cannot interleave with captured
registration writes and resurrect removed credentials. Host foreground loads
await the shared registration activation before accessing Gmail. Each connection has an independent generation, changed on restore, its successful
authorization or removal; account purge invalidates them all. Cache operations validate it after
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
The process-owned `createMailboxes` composition subscribes to registration, keeping
one Inbox per openable Product Account/opaque connection/address/incarnation owner. A changed
owner, refused grant, removal or loss of eligibility forgets only the affected
store immediately and suppresses its late publications. Each store independently
serializes synchronization. The hosts discard Account/Inbox presentation choices when
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

The shared stores keep two body pipelines per connection and four account-wide, coalescing
duplicate reads. A dedicated publication semaphore orders body admission against
each durable metadata commit, body pruning and ready-state publication, including
action intake, dispatch, reconciliation, refusal, label refresh and blocked-action
resolution. Provider action and reconciliation reads remain outside that permit.
Body admission rechecks owner and list membership under that permit, so a late
body cannot repopulate a pruned message or wait for an entire synchronization.
The semaphore has two permits: each independently serialized metadata writer
(synchronization/resolution and intake) takes one, while body admission takes both.
Intake remains able to commit while the other writer awaits a durable reply;
compare-and-swap and the newer-revision publication guard preserve ordering. Each
writer releases its permit before further provider work. Native FIFO custody
alone does not close the gap
between pruning and TypeScript membership publication. Optimistically hidden messages
release in-memory presentations when the durable state publishes; their encrypted
bodies remain eligible while the committed metadata retains them. Undo restores
metadata without reopening a reader, and an explicit reopen uses any retained body.
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
messages receive exclusion markers. An explicit open closes the account-wide interactive latch; an already active speculative item completes, while later items wait.
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

## Provider organization

Issue #607 adds ordered Gmail-only label actions under
[ADR 0015](../adr/0015-optimistic-durable-provider-actions.md).
TypeScript constructs add/remove label intent; native validates the alphanumeric
message ID, label IDs and the bounded count, builds the JSON body, and performs
one credentialed POST to `messages/<id>/modify`. Native credential custody,
redirect refusal, ephemeral response caching and subject/generation fencing remain
unchanged. No Gmail SDK or production dependency is introduced.

The encrypted metadata document retains ordered pending actions, snapshots for
restoration, stable intake IDs, immutable dispatch records and user labels. Each
attempt is durably recorded before dispatch. Lost intake replies deduplicate by
ID. Reconciliation reads current labels before repeating an attempted action;
Gmail's add/remove label operation is idempotent and an observed matching state
confirms without another write. Permanent refusal is committed as an optional
terminal marker in the version-1 pending action before reading current labels.
An interrupted refresh or relaunch reconciles that marker only by restoring
provider-derived state and announcing rejection, without dispatching again;
Retry preserves the marker and reconciliation precedes the attempt-budget gate.
Both marker and settlement commits retain concurrent intake through the existing
base-ID rebase. Rejection feedback checks the initiating ownership epoch after
the label read and precedes settlement commitment, so an interrupted durable reply
does not lose the outcome. `forget` clears it during a pending commit; no late
completion restores the former owner's message in a notice.
Permanent refusal refreshes provider-derived metadata before later
optimistic actions are projected. Automatic activations
respect a five-attempt budget and jittered exponential delay; a blocked head
preserves later actions until explicit retry or authoritative discard.

Intake can commit while the sync loop waits for provider work; native's FIFO
custody gate can still delay that commit behind the one request already in
flight. The UI explicitly says Saving until the native durable reply. A stable
non-secret owner identity binds Product Account, Trusted Device and Google subject;
it lets intake survive generation renewal for the same owner, while a different
owner or a forget epoch fences it. Message snapshots retained by event handlers
are also tied to that owner, so stale handlers cannot mutate another mailbox.

Every native mutation makes a fail-closed credential-only Trusted Device check
before renewing or using the provider credential. A positive rejection purges
before returning the fixed `mailbox-revoked` code; shared recovery clears memory
and queued publications. Read/cache preflight retains its existing offline
availability policy. Undo changes only memberships introduced or removed by the
original action; a pre-existing move target label is preserved.

A fixed `mailbox-revoked` rejection hands the already-purged Inbox to registration
through the host adapter. Shared registration presentation retains the removal
reason across ordinary bare signed-out restores, without replacing an authoritative
deletion notice. Accepted sign-in, sign-out and deletion change its intent fence;
explicit removal and late callbacks cannot relabel a different account operation.
This is TypeScript-owned presentation under ADR 0067; native purge, credential
custody and cleanup ordering remain unchanged.

## Shared presentation budget across connections

`createMailboxes` passes one body coordinator to every connection's Inbox. Besides
its four-load semaphore and interactive latch, it owns the image reservation
ledgers. Each Inbox uses an opaque owner token for its local reader ledger, so
provider message IDs shared by different connections never collide. Admission
sums every ledger and excludes only the reservation being replaced within its own
owner. Forgetting one connection clears and unregisters only its ledger; other
readers retain their charged presentations. A later presentation registers that
owner again. The existing encoded-byte and decoded-pixel bounds therefore remain
shared across all simultaneously displayed readers and Mac windows.

The registration list’s optional `epoch` and native cache-open `owner` both carry
the non-secret connection incarnation. A descriptor removal/recreation learned
during explicit consent can return the same Google mailbox ID and address; the
changed epoch still replaces its Inbox and immediately forgets old plaintext,
unsaved actions and late reads. Ordinary verification keeps the epoch and retains
same-connection work. Older readable epoch-less records use the legacy lifetime
until authoritative reconciliation or current explicit consent binds them.

## Received attachment ownership

Issue [#610](https://github.com/unwired-dev/product/issues/610) implements the on-demand
Gmail slice of [ADR 0030](../adr/0030-gate-incoming-attachment-downloads.md).
`message-body.ts` derives descriptors from the MIME tree without an attachment
request, excluding readable parts, resolved inline images and all attached-message
subtrees. A download rereads the owning message and revalidates the part selector,
name, MIME type and size. Only the verified connection and generation can save it;
bytes never enter the encrypted body cache or Product Sync.

The native credentialed transport caps responses at 40 MiB while receiving them,
including unknown-length responses. TypeScript validates base64url and the exact
25 MiB-bounded decoded size; native storage independently validates that size.
Host adapters forward Effect interruption through an opaque request identifier to
cancel the owning native task and URLSession transfer. Registration refresh checks
cancellation before starting the provider read. Saving and recording ownership are
uninterruptible, with rejected or cancelled saves explicitly discarded.

Private Application Support files are grouped by connection and opaque UUID, with
a confined filename, iOS complete protection and backup exclusion. The 250 MiB
store evicts least recently used files; preview refreshes their modification date.
Files have shorter ownership than the encrypted body: the last reader closing,
the message leaving the Inbox, or the Inbox closing or changing owner discards
them.

For system preview/share, the native bridge retains a counted presentation lease
per file. Reader, message and Inbox discards wait for the last lease; deferred deletion
rechecks ownership under the registration gate. Admission receives the gated
snapshot of leased IDs, counts their bytes toward the same hard limit and skips
them during eviction, refusing before deletion if the remaining files cannot
make space. Connection/account removal
attempts attachment cleanup even when another cache removal fails. Before exposing
the shared registration store, launch clears previous-process files off the main
actor and fails closed if cleanup fails. A post-write authorization rejection also
removes the unacknowledged file.

System preview and sharing receive one resolved connection-owned URL. Native
Quick Look/share runtime behavior and the complete React Native bridge build remain
required qualification; hosted storage/transport fixtures do not establish those
host integration results. See the operational guide's evidence and deferred checks.

## Online Gmail search

Issue #609 uses `messages?q=&maxResults=20` and Gmail's page tokens through the same
native credentialed read. `mail-core` composes each connection's pages, failures and
ordering. A view-scoped search store owns its request generation and answers; replacing
its query, scope, Inbox identities or availability replaces the store before rendering
and disposes its pending publications. Each Mac window owns its search independently.
The hosts subscribe through `useSyncExternalStore` and render local and online rows as separate
sections of one virtualized list. Native requests run to completion; stale answers are
discarded.

Result metadata stays in the connection's memory-only `found` map until forget, allowing
the ordinary isolated reader to open mail outside the cached Inbox. These bodies retain
the existing presentation and image bounds and never enter the encrypted body cache
unless the message is also listed in that Inbox. Search neither persists a body index
nor calls Convex. Controlled TypeScript pagination/failure journeys and native
URLSession search-page responses remain separate from protected live-Gmail evidence.

Received attachments use the same readable-message boundary for explicit downloads
and system presentation, including results outside the cached Inbox. Search membership
does not extend downloaded-file ownership when a listed message leaves the Inbox:
that transition discards its downloads while preserving the search reader's body
and descriptors. An explicit download can then acquire a new file. Synchronization
does not discard an already off-Inbox result's files; its last reader closing or
Inbox owner invalidation still cancels work and discards them.
