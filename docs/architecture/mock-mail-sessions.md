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
returns a fixed summary and translation with a synthetic language list.

Metro resolves the normal seed module to the selected
test module at build time.

The registration journeys use the native registration store and real Keychain
with a fixed synthetic provider compiled only in the selected test build.
