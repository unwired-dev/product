# TestFlight builds

On-demand TestFlight builds of the iPhone/iPad and Mac hosts, for the owner's
devices. Tracked in [#724](https://github.com/unwired-dev/product/issues/724).
The qualified beta and its evidence remain
[#628](https://github.com/unwired-dev/product/issues/628): an uploaded build is
not qualification evidence.

Both hosts upload to one App Store Connect app, `dev.unwired.mail`, with the iOS
and macOS platforms. Builds carry each host's `package.json` version. The build
number is the upload's UTC time, `YYYYMMDDHHMM`. The source commit is in the
app's Info.plist as `UnwiredCommit`.

## Request a build from CI

Anyone with write access can dispatch the
[TestFlight workflow](../.github/workflows/testflight.yml) for any branch in
this repository:

```sh
gh workflow run testflight.yml --ref <branch> -f platform=both
gh run watch
```

`platform` is `ios`, `macos` or `both`. `--ref` selects the workflow revision;
the optional `ref` input builds another branch, tag or commit with that revision.
Each host uploads from its own job, so one can be rerun without the other. Build
logs are attached to the run for seven days.

After the upload, App Store Connect processes the build for several minutes. It
then appears under **Unwired Mail** in the TestFlight app on every device of the
internal testing group.

## Upload from a Mac

```sh
ASC_KEY_ID='<key ID>' \
ASC_ISSUER_ID='<issuer ID>' \
ASC_KEY_PATH="$HOME/Library/Developer/Unwired/AuthKey_<key ID>.p8" \
APPLE_DEVELOPMENT_TEAM='<team ID>' \
UNWIRED_GOOGLE_CLIENT_ID='<native client ID for dev.unwired.mail>' \
UNWIRED_CONVEX_URL='https://<deployment>.convex.cloud' \
mise exec -- zsh scripts/testflight.zsh both
```

The script needs Xcode 27, CocoaPods and the `xcodeproj` gem, as for the
[Mac host](macos-client.md). It regenerates both ignored native projects from
the current checkout, including uncommitted changes. `UNWIRED_DEVELOPMENT_TEAM`
is accepted in place of `APPLE_DEVELOPMENT_TEAM`. Keep the `.p8` file outside
the repository. Archives and logs are written to
`artifacts/testflight/<build number>/`.

## What the script does

```text
scripts/testflight.zsh ios|macos|both
  refuse a selected Mock Mail Session scenario
  generate the native project and install Pods
  xcodebuild archive        # Release, automatic signing through the API key
  refuse an archive whose Info.plist names a mock scenario
  xcodebuild -exportArchive # cloud-managed distribution signing, direct upload
```

No certificate or provisioning profile is stored. Xcode requests development
signing for the archive and cloud-managed distribution signing for the export
through the App Store Connect API key.

Release hosts embed the production-equivalent JavaScript bundle. The bundle
build's `verify:bundle` check rejects mock modules, and Mock Mail Session
scenarios are available only in `Testing` builds, which this script never
produces.

## One-time setup

1. App Store Connect has an app for `dev.unwired.mail` with the iOS and macOS
   platforms, and an internal testing group with automatic distribution.
2. Create a team API key with the **Admin** role under Users and Access →
   Integrations. Cloud-managed distribution signing rejects keys with a lower
   role: the export fails with "Cloud signing permission error".
3. Store the credentials in the `testflight` GitHub environment:

   ```sh
   gh secret set ASC_KEY_ID --env testflight --body '<key ID>'
   gh secret set ASC_ISSUER_ID --env testflight --body '<issuer ID>'
   gh secret set ASC_PRIVATE_KEY --env testflight < AuthKey_<key ID>.p8
   gh variable set APPLE_DEVELOPMENT_TEAM --env testflight --body '<team ID>'
   ```

   The workflow also reads the repository secrets `CONVEX_URL` and
   `GMAIL_OAUTH_CLIENT_ID` as the hosts' public backend configuration.
4. The Convex deployment accepts the hosts: `APPLE_BUNDLE_ID` is
   `dev.unwired.mail` and `GOOGLE_PRODUCT_CLIENT_IDS` includes the native
   client. See [Apple](apple-registration.md#configure-the-hosts) and
   [Google](google-registration.md#configure-the-hosts) host configuration.
