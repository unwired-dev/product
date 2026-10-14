# TestFlight signing

Reviewer-only under the [implementation and review workflow](../agents/implementation-review.md).
Setup, observable behavior and protected validation live in the
[TestFlight operating guide](../testflight.md).

## Reusable identity amendment, 2026-10-14

The owner-authorized [issue #953](https://github.com/unwired-dev/product/issues/953)
supersedes #724's no-stored-signing-identity requirement and #930's blanket
revocation approach. One RSA key belongs to the protected `testflight`
environment. Certificate renewal preserves that key; deliberate compromise
recovery replaces it and revokes its affected certificate. This changes CI
signing custody, not device or provider credential custody in the product.

The workflow queue serializes certificate preparation before parallel upload
jobs. `DevelopmentCertificate` requires a complete development-certificate list,
matches the certificate's public key and team against the configured identity,
and chooses the matching certificate with the latest expiry beyond the two-hour
build window. If none qualifies, it submits a SHA-256-signed CSR with the same
key, then revalidates the returned key, team and lifetime. It does not revoke
certificates. Quota exhaustion fails safely and requires operator verification
of obsolete certificates rather than guessing their ownership from names.

Only public DER crosses the job boundary. Hex encoding prevents GitHub's
line-by-line PEM secret masking from dropping the output when a certificate's
base64 contains private-key PEM lines for their shared RSA public modulus.
Apple's API still supplies base64 certificate content at its HTTP boundary.

Upload jobs use the workflow revision's signing wrapper, even when archiving an
older ref. That checkout lives in the ignored TestFlight artifact directory, so
the archive runner's source-cleanliness check still binds the build to its
stamped commit. The wrapper imports the canonical PEM private key and DER
certificate separately into a temporary user keychain, sends password-bearing
`security` commands through stdin one at a time, and restricts
the user search list to the imported keychain. It confirms that keychain exposes
the expected valid code-signing fingerprint before Xcode can provision. It
removes loose private files before build phases and restores the search list and
deletes the keychain on success, failure and handled signals. Cleanup errors fail
the step. Automatic provisioning and cloud-managed distribution export remain
unchanged. Local invocations retain the developer's own identity.

Credential-free contracts prove real CSR generation, public-key matching,
identity preparation, wrapper orchestration and cleanup with only Apple HTTP and
macOS `security` substituted. A separate native CI preflight uses a synthetic
self-signed identity through the real wrapper, requiring import and key-access
setup to succeed before the expected code-signing trust rejection, then checking
search-list restoration and cleanup. Neither proves Apple issuance, trusted
identity selection by Xcode, processed TestFlight builds or installation. The
operating guide's protected validation remains required release evidence.
