# TestFlight builds

On-demand TestFlight builds of the iPhone/iPad and Mac hosts, for the owner's
devices. Tracked in [#724](https://github.com/unwired-dev/product/issues/724).
The qualified beta and its evidence remain
[#628](https://github.com/unwired-dev/product/issues/628): an uploaded build is
not qualification evidence.

Both hosts upload to one App Store Connect app, `dev.unwired.mail`, with the iOS
and macOS platforms. Builds carry each host's `package.json` version. The build
number is the upload's UTC time, `YYYYMMDDHHMM`. The source commit is in the
app's Info.plist as `UnwiredCommit` and in the build's English TestFlight
**What to Test** notes after App Store Connect finishes processing.

The timestamp has minute precision. Two uploads of the same host and marketing
version in one minute can collide; queue them or wait for the next minute.
CI serializes runs for the same ref, while different refs and local uploads
need that coordination.

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
status evidence is attached to the run for seven days. Raw build and upload
logs stay on the runner because Xcode diagnostics may contain signing tokens.

The workflow deliberately has no approval gate. Write access and the selected
branch's code are trusted with the App Store Connect key; a read-only GitHub
token does not constrain what that code can do with the Apple credentials.

After the upload, App Store Connect processes the build for several minutes. It
then appears under **Unwired Mail** in the TestFlight app on every device of the
internal testing group.

## Upload from a Mac

```sh
mise exec -- zsh scripts/testflight.zsh both
```

Put the same API-key configuration used by CI in the root `.env.local`:

```dotenv
ASC_KEY_ID='<key ID>'
ASC_ISSUER_ID='<issuer ID>'
ASC_KEY_PATH='/absolute/path/outside/this/repository/AuthKey_<key ID>.p8'
APPLE_DEVELOPMENT_TEAM='<team ID>'
UNWIRED_GOOGLE_CLIENT_ID='<native client ID for dev.unwired.mail>'
UNWIRED_CONVEX_URL='https://<deployment>.convex.cloud'
```

The loader reads these release fields and any selected `UNWIRED_MOCK_SCENARIO`
as dotenv data. Exported environment variables override the file; unrelated
fields in the file do not enter builds. A selected mock scenario is rejected.

The script needs Xcode 27, CocoaPods and the `xcodeproj` gem, as for the
[Mac host](macos-client.md). It regenerates both ignored native projects from
the current checkout and refuses to run while tracked changes or non-ignored
untracked files are present. Non-ignored source inputs must match the stamped
commit. `UNWIRED_DEVELOPMENT_TEAM`
is accepted in place of `APPLE_DEVELOPMENT_TEAM`. Keep the `.p8` file outside
the repository. Archives and logs are written to
`artifacts/testflight/<build number>.<run>/`. Each invocation owns its build
directory; DerivedData is removed on success, failure and interruption. Treat
the retained raw logs as private; do not attach them to a public issue or run.

## What the script does

```text
scripts/testflight.zsh ios|macos|both
  refuse a selected Mock Mail Session scenario
  generate the native project and install Pods
  xcodebuild archive        # Release, automatic signing through the API key
  inspect the archived bundle, source map, native test markers and Info.plist
  xcodebuild -exportArchive # cloud-managed distribution signing, direct upload
  wait for processing and record the commit in TestFlight What to Test notes
```

No certificate or provisioning profile is stored. Xcode requests development
signing for the archive and cloud-managed distribution signing for the export
through the App Store Connect API key.

Release hosts embed the production JavaScript bundle. The mobile archive
produces a source map and runs `verify:bundle` against that map. The Mac archive
phase verifies its bundle; the script confirms that the archived bundle and its
source map match those outputs. Both checks reject mock modules. The archive
inspection also checks backend configuration, version, build number and source
commit, and rejects known native Mock Mail Session and external test markers.
This checks the trusted build's packaged boundaries, not arbitrary malicious
changes to the checked-out build script.

The notes helper checks processing at most 40 times, 30 seconds apart, and updates or creates
the English notes for that exact platform, version and build number. A processing
or notes failure makes the script fail even if the binary upload succeeded.
After resolving processing or API access, rerun only the helper with the original
metadata and exported API-key variables:

```sh
ruby scripts/testflight-notes.rb ios <marketing-version> <build-number> <commit-sha>
```

The helper uses Ruby's standard OpenSSL and HTTP libraries. It never prints
signed API tokens or response bodies.

Run the credential-free runner and API-contract checks with
`mise exec -- node --test scripts/testflight.test.mjs`. Runner archive checks
require macOS and substitute build/upload commands; these are not native build
or live App Store Connect evidence.

## Versioned releases

The [Release workflow](../.github/workflows/release.yml) runs on every push to
`main`, tracked in [#725](https://github.com/unwired-dev/product/issues/725).

The plan job runs [`changesets/action`](https://github.com/changesets/action)
with two repository scripts:

```text
push to main
  pending changesets?
    yes -> scripts/release-version.sh runs `changeset version`; the action
           force-updates `changeset-release/main` and opens or updates the
           "Version packages" pull request
    no  -> scripts/release-tag.sh: merged version PR with an untagged version?
           yes -> the action creates tag vX.Y.Z and its GitHub Release from
                  the mobile changelog, then both hosts upload to TestFlight
           no  -> stop
```

Merging the version pull request is the release decision. Both hosts carry the
same version: they are a fixed Changesets group, and both scripts refuse to
continue when they differ. Private packages are versioned but not published or
tagged individually. App Store review submission stays manual in App Store Connect.
If pending changesets advance only backend packages, the version PR also
advances both hosts by a patch, so merging it still selects a new TestFlight
version. Changesets with empty headers alone do not open a version PR; they
ride along with the next non-empty changeset.

The workflow uses the `GH_TOKEN` secret of the `main-token` environment, a
fine-grained personal access token with contents and pull-request write access
to this repository. The default workflow token would not start CI on the version
pull request. The environment's deployment branch policy admits only `main`, so
a workflow pushed to another branch cannot read the token. Keep the token out of
repository secrets, which every same-repository branch can read.

The action commits through the GitHub API, so version commits are signed and
attributed to the token owner. Version planning refuses a pushed commit that is
no longer current `main`, before changing versions or updating the version PR;
run the Release workflow for current `main` instead. Current runs rewrite the
version branch from the pushed commit, including unchanged reruns. Release runs
queue instead of replacing pending runs. The
personal token is available only to the action step; checkout and dependency
installation use the read-only workflow token. That step runs the release
scripts and `changeset version` from the pushed commit, so code merged to
`main` is trusted with the token's contents and pull-request write access.
Limiting the secret to one step does not isolate that code.

If an upload fails after the tag exists, rerun the failed TestFlight job of that
Release run, or dispatch the TestFlight workflow for the tag. Rerunning the plan
job finds the tag at the merge commit and stops without uploading; it refuses a
tag that points to another commit. If the action created the tag but not its
GitHub Release, create it with `gh release create vX.Y.Z --verify-tag`.

```sh
gh workflow run testflight.yml -f platform=macos -f ref=vX.Y.Z
```

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

## Deferred release evidence

Both hosts have previously archived locally with Xcode 27. Export with the
previous API key failed because cloud-managed signing requires the Admin role;
the replacement key is pending. These reviewer changes have credential-free
runner and API-contract checks only. Successful exports, uploaded-artifact
inspection, processed builds with TestFlight notes, and installation from
TestFlight on an iPhone and a Mac remain deferred. They are required before
claiming #724's release evidence or the qualified beta in #628.
