# Microsoft mail: architecture notes

Reviewer-only companion to [the operational guide](../microsoft-mail.md), under
[the implementation and review workflow](../agents/implementation-review.md).
Issue [#634](https://github.com/unwired-dev/product/issues/634) adds a fresh Graph
reader for the replacement hosts, without reusing the prototype mail engine.
[ADR 0069](../adr/0069-expand-the-apple-launch-to-power-user-mail.md) establishes
Microsoft mail at launch; this slice covers own-mailbox authorization and reading.
Microsoft Product Sign-In, organizing, search and sending have separate issues.

## Adapter evaluation

Microsoft offers a [Graph JavaScript SDK and React Native sample](https://learn.microsoft.com/en-us/graph/tutorials/react-native)
and [MSAL for iOS/macOS](https://learn.microsoft.com/en-us/entra/msal/objc/acquire-tokens).
The existence of a sample does not qualify either maintained renderer or permit
JavaScript token custody. MSAL can own native authorization and refresh, but would
add a second credential cache and native dependency to integrate and qualify.
The Graph SDK could construct requests behind a native token-free transport, but
would still need the product's Schema decoding, durable checkpoints, cancellation,
response bounds and ownership fences. No SDK compatibility experiment is claimed.

For this read-only slice, direct Graph REST requests over the existing bounded
native transport keep those boundaries explicit without a new SDK or native
module. TypeScript owns URLs, response decoding and synchronization; native owns
OAuth presentation, token exchange/renewal, credential custody and authenticated
transport under [ADR 0067](../adr/0067-keep-native-code-to-a-minimal-vault.md).
This is a source-and-contract evaluation; live and physical-host qualification
remains required under #637/#855. SDK/broker integration can be evaluated when a
later slice needs capabilities this public-client flow cannot supply.

## Authorization and transport

`GraphMailProvider` uses the Microsoft identity platform's
[authorization code flow with PKCE](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)
and `ASWebAuthenticationSession`. Random state binds both success and error
callbacks; scheme, host, path and unique state/code are validated before accepting
an answer. The common authority admits personal and work/school accounts. Actual
granted `Mail.Read` scope, `/me` identity and own Inbox availability are checked
before connection publication. Reauthorization must match the saved Graph subject.

Access/refresh tokens and expiry are archived only in the existing device-only
Keychain registration record. Refresh begins within five minutes of expiry;
rotated tokens are persisted with the connection. Token exchange uses the same
redirect-refusing bounded transport with a 1 MiB response limit and no bearer
header. Credential-bearing forms cannot follow a redirect to another endpoint. Microsoft authorization never
reuses Product Sign-In's Google credential or introduces Microsoft Product Sign-In.
Native Graph requests validate the connection, generation and process verification
before renewal and after suspension. Gmail refuses Microsoft grants and vice versa.

The Graph URL allowlist admits only HTTPS `graph.microsoft.com/v1.0/me` message,
attachment and own-folder message paths; no shared/delegated `/users` path is
accepted. Continuations support documented `mailFolders`/`mailfolders`, slash and
quoted folder IDs. Responses use the existing ephemeral, redirect-refusing,
bounded `GmailTransport`, and carry `Prefer: IdType="ImmutableId"` and page size 50.
Credentials never cross the bridge; only status/body do.

## Synchronization and identity

`graph-inbox.ts` owns Graph synchronization, attachment metadata and body reads.
The host-facing Inbox store delegates those operations while retaining cache
publication, reader lifetime, prefetch and presentation admission. Both providers
use the same `mailbox-document.ts` cache schemas/reconciliation and
`mailbox-read.ts` request decoding/failures; the exported store interface and
persisted document shapes remain unchanged.

Initial lists follow [`@odata.nextLink`](https://learn.microsoft.com/en-us/graph/api/user-list-messages?view=graph-rest-1.0)
until the newest 200 messages or all available messages are retained, with a
200-page bound. A delta round then durably commits each continuation in the
connection's encrypted document. Its final delta link is retained after relisting
to cover changes during initialization. Later rounds preserve that checkpoint
and restart boundedly on expired delta state. This is the bounded whole-document
cache already used by Gmail, not complete indexed Historical Metadata Backfill.

[Graph delta](https://learn.microsoft.com/en-us/graph/delta-query-overview)
can repeat identities, omit unchanged properties and supply removals in no
reliable order. Each page therefore deduplicates identities and reads their
current own-Inbox metadata (four queued reads); a 404 removes the identity.
A full cache losing an entry relists to refill it. Schema validates list metadata,
delta identities and continuation destinations before use. This avoids deriving
current state from partial or stale change objects.

Microsoft connection/cache IDs and Product Sync descriptor IDs include the
provider with the verified Graph subject. Existing Gmail IDs and encrypted
records stay unchanged. Descriptors carry the encrypted provider/address/epoch,
not tokens or the subject. Body storage and generation, removal, revocation and
compare-and-swap fences remain shared with
[the native cache](private-inbox-storage.md#gmail-mailbox-cache).

## Bodies, images and attachments

Graph's decoded body and separately paginated attachment metadata map to the
existing MIME presentation boundary. Metadata requests select Content-ID and
file fields without `contentBytes`; unsupported item/reference attachments stay
provider-local. Attachment metadata has a 200-page/500-entry bound before tree
construction. Missing or refused metadata leaves text readable, omits the resolved
attachment list from the cache and retries on a later open. Grant refusal also
publishes the owner-fenced authorization notice.

Only sanitized visible CID references read file bytes through shared inline-image
admission, preserving transfer, count, per-image, geometry and account-wide display
bounds. A failed optional image does not replace readable text. Exact decoded
byte sizes are checked against their reserved approximate Graph size. Ordinary
attachments revalidate the current descriptor before explicit download; decoded
sizes enter the existing protected attachment store. Encryption, remote-content
consent, isolated WebKit rendering and cleanup follow
[the shared reader](gmail-inbox.md#message-reading),
[ADR 0029](../adr/0029-sanitize-html-before-webkit-rendering.md) and
[ADR 0030](../adr/0030-gate-incoming-attachment-downloads.md).

## Evidence

Shared store journeys cover realistic continuation pages, partial/repeated delta
identities, relaunch, expired state, image admission/failure, metadata failure and
retry, attachment reads, and Gmail/Microsoft isolation. Native hosted tests use
real local storage and a controlled HTTP boundary through `GraphMailProvider`;
packaged Microsoft-first registration uses synthetic providers. Neither proves
live personal/tenant OAuth, real Graph shapes, physical lock enforcement or Mac
native compatibility. Those remain explicit release qualification prerequisites.
