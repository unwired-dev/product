# Archive compliance engineering record, 15 November 2026

This records the engineering follow-ups to
[#1949](https://github.com/unwired-dev/product/issues/1949). It is preparation for
owner review and store/territory submissions. It does not declare the app cleared
for distribution. France is included in the intended initial release, within the
existing worldwide availability requirement and its territory-clearance limits.
The operator is Unwired, s.r.o.; the owner will sign as its registered director.
No earlier encryption/export filing has been supplied.

## Encryption annex, #2216

The [technical annex](encryption-annex.md) inventories application encryption,
key sizes and custody, recovery/enrollment/rotation, local storage exceptions,
transport implementations, authentication and vendor hash uses. It separates
source facts from historical archive observations and legal classification.

The checked historical TestFlight candidate is version 0.1.0, build
`202611150754`, source `9de3fc7510c693d9aea686345a7199b4188638fc`, run
[43691851806](https://github.com/unwired-dev/product/actions/runs/43691851806).
Its retained artifacts contain reports, not app binaries or complete archives.
The annex explicitly records the different iOS/Mac SwiftNIO-SSL/BoringSSL
revisions. The retained Mac revision's defaults include X25519MLKEM768; observing a negotiated
connection remains separate evidence.

## App Privacy reconciliation, #2217

The [dated privacy evidence](app-privacy-2026-11-15.md) and
[proposed answers](../app-privacy.md) reconcile the exact GoogleSignIn and Sentry
sources, encrypted synchronized content and consented reporting. Both application
manifests now declare the same 15 linked, nontracking types. They retain Google's
partner Analytics purposes. The owner's broader encrypted-content disclosure
choice does not authorize extra collection or alter E2EE.

Current protected checks found all three reporting service variables configured
on the backend deployed by the historical workflow. Aggregate scans found zero
readable email-address rows in the two legacy Gmail tables. These observations
have a date and deployment scope; they do not reconstruct historical settings or
bind the archived app's separately configured backend URL.

The native qualification flag does not disable JavaScript reporting. It remains
false; no native collector was enabled by this work. The existing PostHog deletion
key cannot read project configuration and returned HTTP 403 requiring
`project:read`. An already authorized read-only administration session can close
that inspection without widening the deletion key.

## Notice generation and packaging, #2218

Release builds generate `ThirdPartyNotices.txt` and a SHA-256 coverage record from
the actual JavaScript source map, installed CocoaPods and resolved Swift checkouts.
Both native hosts run generation after JavaScript bundling and before signing.
Debug builds skip this release resource. Generation failures fail the build;
recognised unresolved obligations stay explicit under the existing TestFlight
policy that findings do not themselves block beta upload.

The generator preserves full CocoaPods `FooterText`, local licence texts and
nested vendor notices, including Sentry's `THIRD_PARTY_NOTICES.md`. Empty files and a licence-type string alone cannot supply
notice text. Exact-version/revision supplements recover missing root notices and
vendored terms, including the different BoringSSL revisions and Hermes terms.
Each supplied file has an immutable source URL and a checked hash in
[`scripts/third-party-licences/index.json`](../../scripts/third-party-licences/index.json).
The inventory checks the actual app resource and rejects a mismatched hash.

The exact `standard-navigation@0.0.5` package declares MIT but supplies no
copyright notice in either its published archive or gitHead tree. On 17 November
2026 this attribution was resolved: the maintainer
[confirmed](https://github.com/react-navigation/standard-navigation/issues/7#issuecomment-6474665803)
that the repository's MIT licence applies to all previous versions. The resource
now carries the publisher's
[exact licence text](https://github.com/react-navigation/standard-navigation/blob/33f3d3c976a24bad9fe32583939318bc143fa41b/LICENSE),
`Copyright (c) 2026 React Navigation Contributors`, pinned by SHA-256 in place
of the earlier labelled candidate.

Known composite-library version changes require new notice review. The resolved
Swift graph can include test-only dependencies; listing their notices does not
prove they link into the app. Text coverage also does not establish licence
compatibility or complete binary composition.

## Verification and remaining evidence

The clean baseline at `fda18ae60afe034a5471ede54c13a29d2848014f` passes the repository
pre-handoff check. Targeted integration checks exercise empty acknowledgement
text, missing parent versus nested notices, supplement hash rejection, generated
resources and archive hash verification. The mobile Expo configuration and Mac
privacy plist have matching disclosure types and purposes.

The local arm64 Mac Release build and an actual `.xcarchive` both pass with
Xcode 27.2 and the macOS 27.2 SDK. Generation inside
the native bundle phase produced 138 components and no unresolved notice text.
The actual app resource hash is
`9ad86b38bd6d86612eaa5b1e41c095d4e2c7326e5d688b15f3eb26e384ad4889`.
After local ad hoc signing, `codesign --verify --deep --strict` passes for both
the built app and archived app, and archive
inventory/findings contain no unresolved findings. This app is build `1`, has no
stamped commit and has no configured backend. It is local packaging evidence,
not the historical production candidate.

A task-only Hermes wrapper suppressed compiler warning output after a process
sample showed Xcode's shell-output regex parser stalling on minified warning
lines. This did not change the compiler version, optimization or emitted-code
options. No warning suppression was added to the product build scripts.

The arm64 iOS Simulator 27.2 Release build also passes. Before the
standard-navigation notice was pinned, its native bundle phase packaged 216
components with only `standard-navigation@0.0.5` unresolved, and the notice
text hash was
`90c069819060afc2fba14ec42c9ac2177dbdf2a7a6d9874fd9ba992252023324`.
Ad hoc signature verification passes. Both hosts' text and JSON provenance
resources reproduced byte-for-byte from that generator, manifest and installed
inputs; the pinned notice changes the iOS text and coverage JSON.

On 17 November 2026 an incremental arm64 iOS Simulator Release rebuild, after a
clean generation and build, with the pinned notice and the Expo 58.0.26 patch
releases packages 216 components with none unresolved. Those patch releases had left the exact-version supplements for
`@expo/ui`, `expo-router` and `expo-file-system` stale; they are now pinned to
the publishing Expo commit, with byte-identical texts. The packaged notice text
hash is `730cc1bb8622ba2f69ed557272d8cd4dc56e940ab815379d751305088d5340b2`,
archive inventory verifies it, and ad hoc
`codesign --verify --deep --strict` passes. A fresh arm64 Mac Release build
signed with an Apple Development identity packages 138 components with none
unresolved, at the same notice text hash recorded above, and passes the same
signature check. The scheduled TestFlight run
[44053524060](https://github.com/unwired-dev/product/actions/runs/44053524060)
from `97681a6e8f19da7521dc2fa17ee78fdb5254ec2f`, before both changes, signed
both archives with the prepared identity: Mac packaged 138 components with
none unresolved, iOS 216 with only standard-navigation. A signed archive
carrying the pinned notice waits for the next TestFlight run from `main`.
Both local builds resolve SwiftNIO-SSL 2.37.5 at
`322f3c2a4a21df31c84ca416bf65ee5e9059e440`. The historical iOS inventory also
records 2.37.5; its Mac counterpart records 2.37.6. The annex preserves that
historical difference instead of treating resolved graphs from different builds
as interchangeable. No simulator app was
launched and no physical-device behavior was qualified by these build checks.

On 20 November 2026 React Native macOS 0.83.0 moved the Mac to `hermes-engine`
0.14.1, from `hermes-v0.14.1` at `5a1485fd688eafdf40637f4f2f44ec830f099b80`, and to
`@react-native/*` 0.83.10, from `v0.83.10` at `ff4f96a23b85b30d8de9331dfac2895f385f67b0`.
Their supplements, and those for ReactCodegen and ReactAppDependencyProvider 0.83.0
from `19f618c032c9f07967281ed5c462dc3259e8e7e1`, are re-pinned to those revisions with
byte-identical texts. Every Hermes licence file and extracted vendor source has the
same Git blob as in the reviewed `e0fc67142ec0` tree, and no vendored directory was
added. `@react-native-macos/virtualized-lists` 0.83.0 ships its own licence, so its
supplement is removed. From the inputs of a Mac `Testing` build, the generator now
reports 148 components with none unresolved. Before the re-pin, six were unresolved.
This is local generation evidence, not a signed archive.

Final pre-handoff and independent review outcomes are recorded with the delivery PR.
Local Release builds without production service configuration prove compilation
and resource packaging only. They cannot replace the selected signed production
archive, runtime traffic probes or legal determinations.

Before release, engineering still verifies the selected signed app's backend
binding and resources, physical-device consent/revoke/deletion and no-egress
behavior, actual PostHog project settings/retention, and processor infrastructure
log handling. These checks stay distinct from the completed source inventory and
proposed disclosure matrix. Signer approval, export/territory classification and
filing, App Store Connect answers and legal notice approval remain owner actions.
No legal document, government filing, store answer or upstream message was
submitted by this engineering work. The supplied company extract remains private
and outside the repository and notice resources.

The archive check also verified Xcode's actual `BUILD_DIR`, which changes to
`Build/Intermediates.noindex/ArchiveIntermediates/UnwiredMail/BuildProductsPath`.
The notice script locates the resolved package state through the directory's
ancestors, with an explicit override for a custom package checkout. A regression
fixture exercises both ordinary and archive layouts through the real shell
wrapper and inventory readers. The archived notice resources match the ordinary
build byte-for-byte. This local archive was built unsigned and then ad hoc signed;
it was not exported or uploaded for distribution.
