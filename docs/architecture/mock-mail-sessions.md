# Mock mail sessions: architecture notes

Reviewer-only companion to [docs/mock-mail-sessions.md](../mock-mail-sessions.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Boundaries and scenarios

`createMockMailSession` accepts only a fixed scenario name.

Preview mail comes from the existing synthetic Inbox fixture. Registration
journeys use three synthetic Inbox messages over two pages, an archived label
message and a trashed message through the Gmail adapter and its real encrypted
cache. Except for the [assistance qualification build](../assistance-qualification.md),
assistance returns fixed summary, rewrite, reply and translation text with a synthetic language list.

Metro resolves the normal seed module to the selected
test module at build time.

Registration journeys retain the native vault, real Keychain and encrypted Inbox
store. A relay included only in registration mock targets forwards provider and
backend seams to synthetic Effect layers in `packages/mail-core/src/testing/`.
Metro substitutes their answerer at build time; ordinary targets omit the relay
sources and ordinary bundles use an inert answerer export. The relay projects
non-secret identity and device fields. Synthetic provider tokens and device
credentials are constructed and retained natively, and recovery calls expose
only the public verifier of the native-derived proof to the synthetic backend.

`registration-enrollment` uses the TypeScript synthetic trusted device's fixed
key ring. The mock-only relay reads the requesting device's displayed Enrollment
Code from its run-scoped Keychain item and passes only that text to the synthetic
layer, standing in for entry on another device. The layer seals the ring with
HPKE PSK mode using pure JavaScript `@noble/*` dependencies; production bundles
omit that code. Native CryptoKit opens the approval and retains the requesting
device's private keys. The hosted Swift test opens the same byte-exact approval
that the TypeScript test pins. `registration-recovery` uses that ring's fixed
native-sealed envelopes and a verifier for the journey's fixed Recovery Key. Backend records persist through
the relay's run-scoped Keychain item; mailbox mutations retain their original
launch-only lifetime. Mocked journeys remain separate from real provider and
native qualification under ADR 0060.

`registration-thread` adds six long plain-text messages. Its mock-only native
reply barrier holds Crew 4's full body after the registration operation gate has
released, so other bodies and cache commits can finish. The XCTest runner posts a
bundle-scoped Darwin notification only after dragging and recording a visible
text coordinate. The barrier removes its notification observer on completion or
interruption and refuses after a bounded wait; time never releases a successful
reply. Production does not compile the barrier or its call site.
