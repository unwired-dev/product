# On-Device Mail Assistance qualification

Issue [#416](https://github.com/unwired-dev/product/issues/416) owns the release evidence for
Compose, Response, Understanding, and Translation Assistance. Ordinary pull-request CI proves the
deterministic product contract. A protected run on an Apple Intelligence-capable physical device
then evaluates the current Apple model and Translation framework without using personal or
production mail.

## Versioned synthetic corpus

`MailAssistanceQualificationCorpus.version1` is the source-controlled corpus. It covers prompted
drafting, factual-token preservation, invented commitments, proofreading restraint, all eight
rewrite presets, reply diversity, unanswered questions, source attribution, ambiguity, prompt
injection, bounded long Threads, translation, and the English, German, French, Spanish, and
Japanese qualification locales.

The evaluator does not compare generated prose with a golden string. Each scenario declares
semantic requirements instead: required-term recall, prohibited invented claims, result kind,
distinct reply choices, unresolved-question detection, and admitted-source attribution. Every
scenario must pass all of its applicable checks, and the aggregate score must be at least 0.95.
Changing the corpus, scorer, locales, or thresholds requires a new corpus version so results from
different releases are not mixed.

The ordinary test target runs the corpus through `DeterministicMailAssistanceEngine`. Existing
focused suites remain the authoritative deterministic evidence for:

- privacy admission and prompt-injection resistance;
- explicit invocation, Profile Lock, cancellation, stale input, and error handling;
- one-step semantic editing and undo;
- source-link accessibility labels and unavailable states; and
- Release composer opening, input, formatting, autosave, and main-thread stall budgets.

No live system model is required in pull-request CI.

## Protected physical-device workflow

Create a GitHub environment named `mail-assistance-qualification`. Require an authorized reviewer,
prevent self-review, and restrict deployments to `main`. Register a dedicated, organization-owned
Apple silicon runner in the `mail-assistance-qualification` runner group with the standard
`self-hosted`, `macOS`, and `ARM64` labels. The runner must have Xcode, `jq`, a signed-in
provisioning account, and one connected, unlocked iOS 26-or-newer device that supports Apple
Intelligence. The device must contain no personal account, production mail, Contacts, Calendar
data, or copied real-world content.

Set the environment variable `MAIL_ASSISTANCE_QUALIFICATION_DEVELOPMENT_TEAM` to the non-secret
Apple development team identifier. The workflow accepts the exact device UDID as an input, verifies
that device before Xcode runs, builds an isolated Release test bundle, and selects the physical
qualification suite by its exact test identifier. It also runs the existing local presentation
budget fixture on the same hardware. The compile flag that enables live-model tests is absent from
ordinary CI.

Before dispatch, complete the following checks on that same device:

- [ ] Enable the supported Apple Intelligence model and record the model version without recording
      prompts, transcripts, or generated text.
- [ ] Run the synthetic Translation scenario in both directions and confirm the original remains
      visible until explicit acceptance.
- [ ] Exercise VoiceOver labels and focus order, keyboard traversal, the largest Dynamic Type size,
      sufficient contrast, reduced motion, change review, source links, stale results, and every
      unavailable state.
- [ ] Confirm generation begins only after the assistance surface opens and the person chooses an
      action; closing or locking cancels it.
- [ ] If Apple model feedback is needed, reproduce the problem with a corpus scenario. Never attach
      a real prompt, message, Draft, transcript, preview, accepted output, or model-feedback package
      derived from real mail.

Dispatch from `main` and set all three policy confirmations to true only after the checks above:

```sh
gh workflow run mail-assistance-qualification.yml \
  --ref main \
  -f device_udid='<dedicated-device-udid>' \
  -f hardware_model='iPhone model' \
  -f model_version='<reported-model-version>' \
  -f translation_check_completed=true \
  -f accessibility_check_completed=true \
  -f synthetic_feedback_only=true
```

## Evidence and retention

The workflow retains one artifact for 180 days. Its XCTest result bundles contain the content-free
scorer attachment with corpus version, scenario IDs, capability names, scores, check outcomes, and
durations. `evidence.json` adds the commit, workflow run, public hardware model, OS build, model
version, and gate outcomes. It contains no device UDID, account identifier, recipient, subject,
body, prompt, transcript, preview, accepted output, credential, or model-feedback content.

The app currently emits no production Mail Assistance diagnostics. Future diagnostics may record
only capability, availability category, duration, cancellation, and product-owned error category.
They must never record content or stable mail identifiers.

Record the workflow URL and artifact name on issue #416. Rerun the protected workflow for every
supported OS model update before release, and whenever the corpus, scorer, product instructions,
context limits, system adapter, Translation adapter, or assistance acceptance flow changes.

The workflow terminates and uninstalls only `dev.unwired.mail` from the selected device and removes
its run-owned build directory after evidence upload. After each run, confirm the device has no
retained preview, Draft, synthetic mail, feedback package, installed test app, or running test
process.
