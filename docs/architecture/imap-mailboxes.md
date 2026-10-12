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

`SwiftMailImap` opens one authenticated session for each operation, performs
`EXAMINE`, uses `BODY.PEEK` and closes success and failure paths. TLS starts before
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
MIME parsing feeds the shared sanitizer, with positional capture extraction for
native runtimes, bounded depth/parts and blocked remote content. IMAP reader owners
use the same display allocation coordinator as Gmail, charging repeated images and
simultaneous windows, releasing allocations on reader cleanup and rich-body failure.

Product Sync descriptors carry `provider: imap`. The native receipt's subject is
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

After a successful decoded `connectImap` result, the registration subscription
publishes the matched connection ID as repair metadata. `createMailboxes` reconciles
owners first, then reloads that connection's Inbox if it was retained across the
change, whatever its status, to reopen its native generation. A newly opened or
owner-replaced Inbox follows its normal initial load. Snapshot identity alone
never dispatches repair reads.

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
power-user parity remain explicitly unqualified. Receive-only behavior until #631
and the reduced reader are settled scope, not defects to reverse in this review.
