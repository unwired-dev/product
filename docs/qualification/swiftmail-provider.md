# SwiftMail 1.10.0 Provider Compatibility Run

SwiftMail is an approved, exact-pinned app dependency, but issue [#280](https://github.com/unwired-dev/product/issues/280) still requires live iCloud Mail and Fastmail Mail Test Evidence before Standards-Based Mailbox Connections can be enabled in an externally distributed Release build. The Provider Compatibility Run package remains deliberately separate from the app project and independently verifies tag `1.10.0` at commit `c907f871bb23812895274f4c7ae17bf343171c1e`; provider credentials and the 10,000-message qualification fixtures never enter ordinary pull-request CI.

## Protected environment and accounts

Create a GitHub environment named `swiftmail-provider-qualification`. Configure required reviewers, prevent self-review, and allow deployments only from protected branches. Ordinary pull-request CI never references this environment or receives its secrets.

Use two disposable Provider Test Mailboxes/Tenants containing no personal mail. Store their app-specific credentials only as environment secrets:

| Secret | Purpose |
| --- | --- |
| `ICLOUD_QUALIFICATION_EMAIL` | Dedicated iCloud Mail address |
| `ICLOUD_QUALIFICATION_PASSWORD` | Dedicated iCloud app-specific password |
| `FASTMAIL_QUALIFICATION_EMAIL` | Dedicated Fastmail address |
| `FASTMAIL_QUALIFICATION_PASSWORD` | Dedicated Fastmail app password |

The workflow accepts these optional environment variables. They are identifiers, not credentials:

| Variable | Default or purpose |
| --- | --- |
| `ICLOUD_QUALIFICATION_DATASET_MAILBOX` | `Unwired Qualification Dataset` |
| `FASTMAIL_QUALIFICATION_DATASET_MAILBOX` | `Unwired Qualification Dataset` |
| `*_QUALIFICATION_SENT_MAILBOX` | Exact manual mapping only when the provider omits an unambiguous `\Sent` attribute |
| `*_QUALIFICATION_JUNK_MAILBOX` | Exact manual mapping only when the provider omits an unambiguous `\Junk` attribute |

Manual mappings are validated against the exact server listing. The runner never calls SwiftMail's name-based role helpers, so localized names are not guessed.

## Dataset preparation and invocation

The first protected run prepares each dedicated account:

```sh
gh workflow run swiftmail-provider-qualification.yml \
  -f provider=both \
  -f prepare_dataset=true
```

Preparation creates the stable dataset and scratch fixture mailboxes when absent, then appends enough deterministic messages to make the dataset exactly 10,000 messages averaging 2 KiB. SwiftMail 1.10.0 does not expose mailbox deletion, so the empty scratch mailboxes are persistent account fixtures. Run-owned messages are still removed after every success or failure.

Normal Provider Compatibility Runs must not prepare or alter the dataset:

```sh
gh workflow run swiftmail-provider-qualification.yml \
  -f provider=both \
  -f prepare_dataset=false
```

Each selected provider step receives only that Provider Test Mailbox/Tenant's protected secrets and emits redacted JSON Mail Test Evidence retained for 90 days. The Mail Test Evidence contains provider name, exact SwiftMail tag and commit, whether dataset preparation was enabled, pass/fail checks, request and page counts, decoded metadata bytes, process CPU time, provider/network wait time, peak resident-memory increase, and maximum main-thread stall. It contains no address, credential, mailbox name, subject, body, UID, or Message-ID.

For a final `provider=both` run with `prepare_dataset=false`, the workflow verifies the two reports together before succeeding. The offline verifier requires exactly one passing report for each provider, the exact SwiftMail pin, every required check and metric, ADR 0027 budget compliance, and evidence that dataset preparation was disabled. Preparation-run reports remain useful diagnostics but cannot pass final-evidence verification.

Downloaded reports can be verified again without provider credentials:

```sh
swift run --package-path tools/swiftmail-provider-qualification \
  swiftmail-provider-qualification --verify-evidence \
  /path/to/icloud.json \
  /path/to/fastmail.json
```

## Automated checks

The live runner verifies:

- TLS 1.2-or-newer IMAP and SMTP password authentication;
- canonical Inbox plus unambiguous server-returned SPECIAL-USE roles or exact validated manual mappings;
- permitted creation of a missing product-role mailbox and exact mapping without name inference;
- newest-50 metadata and complete newest-first history across bounded 500-message UID pages;
- no-change and 100-message flag reconciliation within ADR 0027's request, decoded-download, page-size, memory, and main-thread limits;
- selected text body-part fetching and provider-backed BODY search, including absent, header-only, and mailbox-excluded false-positive cases;
- read/unread reconciliation and a junk-role round trip with verified `COPYUID` mappings;
- IDLE events before and after a renewal plus bounded `DONE` cancellation;
- final SMTP acceptance, self-delivery, and a Sent append whose `APPENDUID`, `UIDVALIDITY`, and fetched bytes are verified; and
- cleanup by the unique run header and subject using only `UID STORE +FLAGS \Deleted` and `UID EXPUNGE`.

The runner never calls unrestricted `EXPUNGE`, never closes a selected mailbox with `CLOSE`, and never deletes or moves a message that lacks the run's random marker.

## Manual soak checklist

Record the workflow run URL and Mail Test Evidence names for both providers, then complete this checklist without copying credentials or mail content into the issue or evidence:

- [ ] Confirm the environment required an authorized reviewer and the run originated from a protected branch.
- [ ] Confirm both Mail Test Evidence files name SwiftMail `1.10.0` and commit `c907f871bb23812895274f4c7ae17bf343171c1e`.
- [ ] Leave IDLE active through at least two provider keepalive windows and confirm events continue after renewal.
- [ ] On a controlled runner, interrupt networking during IDLE, restore it, and confirm the next run-scoped append is observed after automatic reconnect and mailbox reselection.
- [ ] Cancel an active IDLE run and confirm the job exits without a lingering process or later callback.
- [ ] Confirm SMTP delivery appears in the dedicated recipient account and the explicit Sent append has one valid UID/UIDVALIDITY identity.
- [ ] Confirm the Mail Test Evidence records provider/network wait separately from process CPU time and all ADR 0027 non-wall-clock budgets pass.
- [ ] Search Inbox, Sent, Junk, and both scratch mailboxes for the run identifier and confirm no run-owned message remains.
- [ ] Confirm the 10,000-message dataset remains intact and no message outside the qualification fixtures changed flags or location.

Do not mark #280 complete until both Provider Compatibility Runs pass and this checklist is attached as credential-free Mail Test Evidence.
