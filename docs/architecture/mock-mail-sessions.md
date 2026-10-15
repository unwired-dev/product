# Mock mail sessions: architecture notes

Reviewer-only companion to [docs/mock-mail-sessions.md](../mock-mail-sessions.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Boundaries and scenarios

`createMockMailSession` accepts only a fixed scenario name.

Preview mail comes from the existing synthetic Inbox fixture. Registration
journeys use a three-message synthetic Gmail mailbox over two pages through the
new Gmail adapter and its real encrypted cache. Assistance
returns fixed summary, rewrite, reply and translation text with a synthetic language list.

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

`registration-enrollment` retains its native synthetic trusted device until
[#960](https://github.com/unwired-dev/product/issues/960), because it seals a live
HPKE approval. `registration-recovery` uses fixed native-sealed envelopes and a
verifier for the journey's fixed Recovery Key. Backend records persist through
the relay's run-scoped Keychain item; mailbox mutations retain their original
launch-only lifetime. Mocked journeys remain separate from real provider and
native qualification under ADR 0060.
