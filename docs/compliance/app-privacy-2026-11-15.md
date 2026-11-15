# App Privacy reconciliation, 15 November 2026

Evidence for [#2217](https://github.com/unwired-dev/product/issues/2217) and
[#1949](https://github.com/unwired-dev/product/issues/1949). The
[App Privacy answers](../app-privacy.md) own the proposed label. This record
captures what was checked and what remains unverified. It is not a submission or
release qualification.

## Reviewed sources and disclosure choice

The source review began at `fda18ae60afe034a5471ede54c13a29d2848014f`.
Historical archive evidence is build `202611150754`, source
`9de3fc7510c693d9aea686345a7199b4188638fc`,
[TestFlight run 43691851806](https://github.com/unwired-dev/product/actions/runs/43691851806).
Its retained iOS and Mac artifact bundles contain inventories and upload status,
not the app or its Info.plist.

On 15 November the owner selected collected, linked App Functionality disclosure
for synchronized Draft subject, sender, recipients and body, Draft photos/images,
Draft files and mailbox descriptions. The correction changes neither E2EE key
custody nor OAuth scopes. On-device processing remains separate. Apple's
collection and partner definitions require considering more than readable
first-party database fields. Recurring collection after one consent request is
not exempt from disclosure.
[Apple App Privacy](https://developer.apple.com/app-store/app-privacy-details/).

The proposed 15-type matrix retains all eight Google SDK declarations and their
purposes, adds the three selected synchronized-content categories, and includes
consented diagnostics. All rows are linked and not used for tracking. Broader
partner declarations are conservative disclosures; they are not assertions that
a runtime trace observed every category. Both app manifests use the same matrix
and preserve vendor manifests and required-reason API declarations.

## Google sign-in

GoogleSignIn is pinned to version 10.0.0. The pod's `10.0.0` tag resolves to
`7823e518f5d4db765ccac3e140dd3265ef0a1cf1`. Source downloaded by tag was checked
byte-for-byte against that commit. Both historical archive inventories contain
the following linked, nontracking vendor declarations:

| Types                                              | Purposes                     |
| -------------------------------------------------- | ---------------------------- |
| Name, Email Address, Phone Number, Coarse Location | App Functionality            |
| User ID, Other Data Types                          | App Functionality, Analytics |
| Device ID, Other Usage Data                        | Analytics                    |

The app's `native/private-inbox/bridge/UnwiredRegistration.swift` uses the standard
Google sign-in adapter with no extra Product Sign-In scope and only the existing
Gmail scope for mailbox authorization. It archives the returned `GIDGoogleUser`
into the device-only credential and clears the SDK's transient cache. This does
not establish provider grant revocation or deletion.

The SDK's `GIDScopes.m` adds `email` and `profile`; `GIDSignIn.m` parses profile
name, email and image from the ID token or userinfo response. No phone-number
scope or phone extraction was found in the app adapter.
`GIDSignInPreferences.m` sends SDK version `gpsdk`, execution environment `gidenv`
and an optional wrapper identifier `gidwrapper` with OAuth requests. This
metadata is separate from Unwired's unimplemented product analytics.
[Pinned manifest](https://github.com/google/GoogleSignIn-iOS/blob/7823e518f5d4db765ccac3e140dd3265ef0a1cf1/GoogleSignIn/Sources/Resources/PrivacyInfo.xcprivacy),
[scopes](https://github.com/google/GoogleSignIn-iOS/blob/7823e518f5d4db765ccac3e140dd3265ef0a1cf1/GoogleSignIn/Sources/GIDScopes.m),
[sign-in implementation](https://github.com/google/GoogleSignIn-iOS/blob/7823e518f5d4db765ccac3e140dd3265ef0a1cf1/GoogleSignIn/Sources/GIDSignIn.m),
[metadata](https://github.com/google/GoogleSignIn-iOS/blob/7823e518f5d4db765ccac3e140dd3265ef0a1cf1/GoogleSignIn/Sources/GIDSignInPreferences.m).

Google's SDK privacy page describes a user identifier for OAuth grants and
IP-derived general location for fraud prevention. It neither explains every
category/purpose in the broader manifest nor supplies per-type retention limits.
Google's general retention policy permits extended retention for security/fraud
purposes. These sources do not establish request-only retention. The proposed
answers retain the broader declarations until version/configuration-specific
evidence supports narrower ones.
[SDK privacy disclosure](https://developers.google.com/identity/sign-in/ios/app-privacy),
[retention policy](https://policies.google.com/technologies/retention).

## Sentry and application reporting

`native/private-inbox/Package.swift` pins Sentry Cocoa 9.30.2 to
`4bb2282661ee6ca2212aa01d19a1214394cd3c45`. The historical vendor manifest lists
Crash Data, Performance Data and Other Diagnostic Data as unlinked App
Functionality. The application adds an independent installation UUID to its
projected reports, so the proposed application answers mark diagnostics linked.

`ErrorReportingCollector.swift` configures a local DSN, an ephemeral URLSession
with a blocking URLProtocol, and `beforeSend` that emits a local allowlisted
projection and returns nil. Automatic sessions, performance, hang/watchdog,
network/file tracking, breadcrumbs and default PII are disabled. The pinned
transport factory uses the supplied `options.urlSession`. These source checks
support the intended disconnected SDK transport; a signed-device no-egress probe
remains deferred.
[Pinned transport factory](https://github.com/getsentry/sentry-cocoa/blob/4bb2282661ee6ca2212aa01d19a1214394cd3c45/Sources/Sentry/SentryTransportFactory.m).

`ErrorReportingRuntime` makes reporting available in ordinary non-mock Release
builds with a valid Convex URL. Debug builds need the qualification flag.
`UnwiredNativeErrorReportingQualified` only gates starting the native collector.
It does not disable JavaScript reporting or the app's Convex transport.

The shared JS store projects allowlisted failures and maintains consent, the
bounded queue and deletion state. The native transport adds installation proof
and generation, then calls fixed Convex reporting endpoints. The receiver
requires three `POSTHOG_*` variables before forwarding captures to PostHog EU.
Its enable/revoke/delete/status control can retain minimal installation state
without capture configuration. Configured keys do not prove ingestion or
verified deletion.

The receiver sets `$geoip_disable: true`, sends no client-IP property, and creates
a minimal person profile for deletion. It does not forward arbitrary errors,
mail or account identity. Independent APNs service-health reports carry fixed
identity-free fields. PostHog receives the backend network address; source code
alone does not establish processor infrastructure-log handling.

## Production observations

Read-only checks on 15 November used the existing local Convex authentication.
The successful Convex deployment line in run `43691851806` uniquely matched one
accessible current production deployment. No deployment was provisioned, no
function was deployed, and no authentication configuration changed.

On that deployment, `convex env list --names-only` confirmed all of
`POSTHOG_PROJECT_KEY`, `POSTHOG_PROJECT_ID` and `POSTHOG_PERSON_API_KEY` configured.
This corrects the old assertion that no reporting service was provisioned.

A sandboxed `convex run --inline-query` counted at most 10,001 rows per table and
returned only aggregates:

| Table                          | Scanned | Readable `emailAddress` rows | Capped |
| ------------------------------ | ------: | ---------------------------: | ------ |
| `mailProviderConnections`      |       2 |                            0 | No     |
| `gmailPushVerificationSignals` |       0 |                            0 | No     |
| `errorReportingInstallations`  |       1 |                            0 | No     |
| `errorReportingDeliveries`     |       0 |                            0 | No     |

The zero legacy-address count applies to this deployment at observation time.
It does not prove historical emptiness or infrastructure-log contents.

GitHub's `testflight` environment has `POSTHOG_CLI_API_KEY` configured,
`POSTHOG_CLI_PROJECT_ID` set, and `POSTHOG_CLI_HOST` equal to the expected EU host.
These are symbol-upload settings, separate from receiver configuration.

A read-only PostHog project-settings request using the existing person/deletion
key returned HTTP 403 and explicitly required `project:read`. The credential was
used only in memory. No secret values, account identifiers, addresses or mailbox
records were printed or retained.

## Archive configuration and binding limits

Both inventories identify the build/source above and contain Google's and
Sentry's declarations. Their own app manifests have the previous five-type
matrix. The upload status reports success. At that revision, the upload script
rejects mock builds and verifies version/build/source and configured backend
against build inputs. It refuses upload unless
`UnwiredNativeErrorReportingQualified` is false, and sets reporting channel
`testflight`. This supports the historical native gate being false; it is not a
runtime qualification.

The archive backend URL is masked in retained logs. The build uses a separate
`CONVEX_URL` secret; the workflow does not compare it with the deploy job's
output. The production observations therefore identify the historical deployed
backend, while the archive's actual backend remains to be matched. Current
variables and counts do not reconstruct configuration at archive time.

## Remaining checks

- Compare the owned signed app's `UnwiredConvexURL` with the checked deployment in
  memory and record only a match boolean. Record build/source/channel/native-gate
  values. If the backend differs, repeat the bounded aggregate there.
- Run fresh-off, upgrade-off, opted-in JS failure, offline/revoke and relaunch,
  sign-out and deletion on owned iPhone, iPad and Mac resources. Use synthetic
  sensitive markers to verify the outgoing allowlist. Keep native capture off
  until #1050 proves consent, purge and no SDK egress on each platform.
- Read PostHog settings with separate authorized `project:read` access. Do not
  widen the shipped deletion key. Verify the actual Free plan, IP configuration,
  synthetic ingestion/readback, source mapping, deletion and quota behavior.
- Inspect actual Convex/PostHog processor logs, configured sinks and retention
  through authorized read-only administration. The schema's lack of an IP field
  is not a no-IP-retention guarantee. Convex's public log guidance does not supply
  that guarantee. [Convex debugging](https://docs.convex.dev/functions/debugging).

PostHog's public Free-plan retention is one year for events, without a guaranteed
physical deletion deadline at expiry. Person profiles remain until explicit
deletion. This is separate from the app's 24-hour unsent queue. Actual project
settings remain unverified. Discarding IP properties alone does not disable
location transformations; the receiver also sets GeoIP off for each event.
[PostHog retention](https://posthog.com/docs/data/events-retention),
[collection controls](https://posthog.com/docs/privacy/data-collection).

## Checks on this correction

The evaluated `expo config --type public --json` matched the Mac manifest's 15
unique linked, nontracking entries, retained every pinned Google purpose, and
kept native qualification false. Mobile type-aware lint and `tsc --noEmit`, Mac
`plutil -lint`, targeted formatting and relative documentation-link checks passed.
No native build, launch, simulator interaction or vendor mutation was performed.
The runtime and processor checks above remain deferred.
