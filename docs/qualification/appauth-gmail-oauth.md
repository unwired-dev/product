# AppAuth Gmail OAuth qualification

AppAuth-iOS is pinned at version `2.1.0`, commit
`a7caeda164dc5108bf4649472b28a5af65dc6f33`, under Apache-2.0. It is an internal-only Gmail
Mailbox Authorization candidate. Externally distributed Release builds continue using the current
native OAuth flow.

## Deterministic evidence

`AppAuthGmailOAuthServiceTests` verifies the exact Google endpoints, `openid`, `email`, and
`gmail.modify` scopes, absent client secret, AppAuth-generated state and nonce, S256 PKCE, consent
denial and user/program cancellation mapping, interrupted-callback error preservation, two
overlapping authorizations completed in reverse order without token crossover, missing token
rejection, and the fail-closed build selector.

The candidate rejoins the existing connection pipeline after the token exchange. Its established
tests remain the contract for the responsibilities that AppAuth must not take over:

- `GmailProviderConnectionServiceTests` covers two independently stored Gmail identities,
  device-only Keychain attributes, restoration, rotated and non-rotated refresh tokens, revoked
  grants, missing scopes, Gmail profile access, and mismatched Google subjects.
- `MailboxConnectionAdapterTests` covers wrong-identity reconnection, connection-scoped rollback,
  device-only disconnect, synchronized removal, authorization-generation changes, and preserving
  unrelated connections.
- Product Sync boundary tests reject credentials and identity tokens from synchronized records.

Run the focused deterministic contract on a run-owned iPhone 17 Simulator:

```sh
xcodebuild test \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail \
  -destination 'platform=iOS Simulator,id=<owned-udid>' \
  -parallel-testing-enabled NO \
  '-only-testing:unwired-mailTests/AppAuthGmailOAuthServiceTests' \
  '-only-testing:unwired-mailTests/GmailProviderConnectionServiceTests'
```

## Build and package impact

The qualification build uses Xcode 26.4 with the iOS 26.5 Simulator runtime and the exact SwiftPM
pin above. Measurements use fresh DerivedData directories, Release, the active simulator
architecture, testability, and the repository's Release performance compilation conditions.

| Measurement | Existing implementation | AppAuth candidate | Delta |
| --- | ---: | ---: | ---: |
| app executable | 100,683,104 bytes | 101,171,040 bytes | +487,936 bytes (+0.48%) |
| `.app` bundle | 100,212 KiB | 100,732 KiB | +520 KiB (+0.52%) |
| Swift compilation time | 271.120 seconds | 249.504 seconds | -21.616 seconds |
| C/Objective-C compilation tasks | 412 | 448 | +36 tasks |

The timing values are one clean sample per revision on the same host and are not evidence of a
speed improvement; host cache and scheduling noise dominate the observed decrease. The binary and
bundle measurements are the decision inputs. AppAuth adds about half a percent to each while its
Objective-C implementation adds 36 compile tasks.

The AppAuth and AppAuthCore privacy manifests declare no tracking, collected data, or
required-reason API access. The app does not persist `OIDAuthState`; its existing connection-scoped
Keychain entries remain `AfterFirstUnlockThisDeviceOnly`, and identity tokens remain excluded from
token persistence.

## Migration cost and removable code

The qualification adds 370 product-source lines and 232 focused test lines. A production migration
would move the four-line `GmailOAuthAuthorizing` protocol to a neutral file, make the candidate the
default, remove its environment selector and qualification-only snapshot surface, and delete the
343-line `GoogleGmailOAuthService.swift` implementation after a release soak. That deletion removes
the handwritten authorization URL, random state, PKCE challenge, callback/state parser,
`ASWebAuthenticationSession` lifecycle, form encoding, token-response model, and authorization-code
exchange. The existing verifier, connection service, Keychain store, product errors, and their
tests remain because they enforce product policy rather than OAuth mechanics.

No credential or Product Sync migration is needed: both implementations produce the same
`GmailProviderTokens` value and the candidate does not persist AppAuth state. Until the live run
passes, the source cost is intentionally additive and production keeps the current path.

## Protected Provider Compatibility Run

Do not start a provider-backed run until the redacted record in
`docs/gmail-provider-test-tenant.md` says `status: ready` and every required control is attested.
Use only the two synthetic Provider Test Mailboxes, an internal OAuth audience, and the approved
scope set. Do not record addresses, client identifiers, tokens, authorization codes, subjects,
screenshots of account data, or browser URLs.

In an internal Debug build, set `UNWIRED_GMAIL_OAUTH_IMPLEMENTATION=appauth`. Capture only the
candidate version/revision, device/runtime, pass/fail scenario names, error category, and whether
cleanup completed.

Run and record these checks:

- [ ] Authorize both test mailboxes, relaunch, refresh both, revoke one grant, and disconnect each;
      every operation affects only its Mailbox Connection.
- [ ] Start two authorizations before either completes, finish them in reverse order, and verify
      each resulting connection has the selected identity and no token crossover.
- [ ] Deny consent and cancel the browser; each attempt returns to that connection's
      authorization-required state without changing the other connection.
- [ ] Lock and unlock the device while the system browser is active, then repeat while returning
      the callback; the attempt either resumes correctly or reports a connection-scoped retry.
- [ ] Interrupt one callback by backgrounding and terminating the app, relaunch, and verify no
      partial credential or global pending session is restored.
- [ ] Force refresh-token rotation in the protected tenant, refresh, relaunch, and verify the
      rotated token restores only its connection.
- [ ] Revoke one grant and verify its refresh reports authorization required while the second
      connection can still refresh and use Gmail.
- [ ] Remove `gmail.modify` from one grant and reconnect; scope verification must reject it.
- [ ] Attempt to reconnect an existing connection while selecting the other Google identity;
      identity verification must reject the replacement and preserve the existing credentials.
- [ ] Disconnect both connections and verify the run leaves no test credential, pending browser
      session, or run-owned message data on the device.

Attach the credential-free result to issue #435. A full pass permits a separately approved
production migration proposal. Any failure rejects the migration until fixed and re-run; do not
enable AppAuth in Release merely because deterministic tests pass.
