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
`history`, `labels`, `messages` and alphanumeric `messages/<id>` paths below
`https://gmail.googleapis.com/gmail/v1/users/me/`. It renews and attaches the
mailbox credential, preserves repeated query parameters, refuses redirects and
returns only status/body. The ephemeral URL session keeps HTTP response caches
off disk. Native and TypeScript diagnostics use fixed allow-listed values.

The bridge exposes `gmailRequest(path, query, mailbox)`, `gmailModify(change, mailbox)`, `openMailbox()` and
`commitMailbox(mailbox, expectedRevision, document)`. The cache reply contains
revision, address, an opaque native generation, a non-secret owner identity and an optional document, with `availability: retry` only for
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
