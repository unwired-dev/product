Repository review checklist (reviewer-only). These rules direct the OpenAI/Codex host's architecture review during implementer handoff; OCR resolves inputs and does not prove architecture correctness. Apply the common sections to every task-owned file. Apply a conditional section when a changed file or collaborating module affects that boundary, regardless of its directory. Do not impose planned replacement behavior on retained prototype code or expand launch scope. Read the authoritative sources before deciding; this checklist is not a replacement for them.

Every path rule under `.opencodereview/rules/` includes this checklist by reference, and the fallback entry resolves it directly. A path rule adds the concrete defects of one code area; apply it within the common scope and the owning authoritative decision. A path rule cannot override an accepted decision or a documented exception.

#### R0 — Reporting bar (all files)

Report a defect only when the change introduces or worsens it and the context you read makes it reachable; a false positive costs reviewer trust. Before claiming non-local behavior, read the callers, the owning module and the test that covers it, and cite `path:line` for each claim. State the failure: the input or state, and what goes wrong. Privacy, identity isolation, encryption, data loss and duplicate delivery findings block; a maintainability finding blocks only when it breaks a rule in the resolved checklist.

The maintained CI runs oxlint, oxfmt, `tsgo` type checking, Effect diagnostics, Fallow, the changeset gate and bundle checks. Leave findings those checks decide to them unless the change disables, exempts or weakens the check: a new or broadened `oxlint-disable`, `fallow-ignore`, `@effect-diagnostics`, lint override, `ignorePatterns` entry or skipped test needs a stated reason and the narrowest scope, and is itself a finding without them. SwiftLint and swift-format are not maintained CI gates; report which native or prototype checks actually ran and defer unavailable checks accurately.

#### R1 — Authority, scope and context (all files)

Read applicable AGENTS.md files, docs/agents/implementation-review.md, docs/architecture/README.md, docs/agents/domain.md, and the relevant architecture companions. Read ADR 0059 through 0065 by their full filenames in docs/adr/README.md, plus affected earlier or later decisions and relevant .patterns/, research, qualification and archive sources. Explicit replacement supersessions take precedence over prototype behavior; historical plans and glossary entries do not establish first-release scope or passing qualification. Match the originating issue/specification and preserve applicable requirements and decisions. Where sources conflict or a change requires a new decision, report the conflict rather than silently changing scope. Follow linked operational guides for coding, setup, native validation, testing and delivery. Inspect full-file context and collaborating modules, not just changed lines.

#### R2 — Review coverage (all files)

Use the handoff's actual pinned comparison and inventory task-owned staged, unstaged, untracked and committed changes; preserve pre-existing unrelated work. The first OCR pass and every thermo-nuclear or applicable design pass cover the full task. An OCR follow-up may use only the validated incremental checkpoint plan from `docs/agents/implementation-review.md`; verify its exact range and prior report, inspect affected context and prior findings, and distinguish carried-forward coverage from newly reviewed changes. A missing or invalid checkpoint, changed base or review inputs, invalid ancestry or uncommitted work requires the workflow's full-review fallback.

Reconcile OCR previews with the selected Git diff and task-owned untracked inventory, keyed by (path, status), including deletions and staged deletion/untracked recreation pairs. OCR exclusions never waive review: apply this repository checklist manually to excluded task-owned text and review other excluded artifacts through their relevant owning interfaces without exposing secrets. Check both the requested behavior and repository standards, privacy boundaries, collaborating modules and meaningful test coverage. Cover every change in the selected comparison, not a single commit from a multi-commit range.

#### R3 — Validated findings and evidence (all files)

Match local validation to the actual CI invocation and gate, not only a similarly
named package script. For Fallow changes, check `.github/workflows/ci.yml` and run
`git fetch origin main` followed by
`mise exec -- pnpm exec fallow audit --root . --quiet --changed-since origin/main --gate new-only`.
Record the audit verdict; `pnpm fallow` reports health findings without enforcing
that new-only gate and cannot establish a pass. Leave individual tool-decided
complexity/duplication findings to Fallow, while reviewing suppressions under R0.

For saved benchmark aggregation such as `tools/system-category-benchmark/report.py`
`runs()`, verify each result's frozen corpus and compatible experiment identity
against the current inputs, preprocessing, training settings and dependencies.
Recording configuration fields without checking compatibility is insufficient;
partial reruns must not silently combine stale and current results. Preserve
intentional model, input-budget and seed variants. Before backfilling provenance,
verify the old artifacts' corpus and experiment from recorded execution evidence
and history rather than asserting that every existing result is current.
Apply the same compatibility checks when assembling frozen candidate bundles,
including referenced System results in `custom_report.py` `golden()`; validating
only Custom results or table aggregation still admits stale native prerequisites.

For frozen-input exports such as `tools/deberta-mac-spike/export.py`, verify
companion artifacts as well as weights before replacing output or copying them
into the native bundle. A matching weights hash does not establish tokenizer
identity; require the companion's frozen provenance or verified digest, or an
export can silently change token IDs while claiming the frozen pipeline.

Independently reproduce or substantiate each finding against source and applicable decisions. Fix confirmed issues in the authorized checkout, preserving unrelated work; update affected tests and operational/architecture documentation. Rerun appropriate checks, refresh coverage and resolved rules after edits, and rereview the corrected artifact until no in-scope issue remains. Reviewer fixes stay within this review; later implementer edits require a new pinned review. Report sources consulted, applicable conditional sections and their dispositions, coverage, validated findings/fixes, changed files, checks/results, unavailable tooling and unresolved decision blockers. Separate OCR selection/rule-resolution evidence from host reasoning and actual integration/native/CI evidence; an unavailable check is deferred or blocked, never passing. Do not disclose architecture source or rule bodies in the implementer handback. Review completion and required CI are independent.

#### R4 — Identity, authorization and recovery (conditional)

For registration, linking, credentials, device/account lifecycle or Private Sync changes, read ADR 0061, applicable ADRs 0001, 0002, 0009, 0010, 0020 and 0021, and the identity, registration, linking and private-product-sync companions under docs/architecture/. Keep Product Sign-In, Trusted Device proof, Gmail authorization and decryption-key possession separate. Verify issuer/subject/audience, nonce/expiry and actual mailbox grant at their owning boundaries; backend verification cannot be replaced by client checks. Never merge accounts by email or infer mailbox consent from identity permission. Missing, expired, stale or cancelled mailbox authorization must retain the appropriate resumable setup/reconnect state instead of claiming a connected inbox. Scope provider identities, mailbox/thread state, restored credentials and keys to their owning account, connection, device and deployment. Missing local keys on an initialized account must use trusted-device approval or the user-held Recovery Key, never replacement keys or implicit reset. Preserve recent-authentication requirements for the specific sensitive operations that require them, enrollment/recovery identity and epoch fences, durable adoption before cleanup, revocation/rotation and account-deletion guarantees. Product Sign-In alone supplies neither mailbox access nor Private Sync keys; provider mail is untouched by encrypted-data reset or device cleanup unless the authorized operation explicitly requires otherwise.

#### R5 — Encrypted storage and Private Sync (conditional)

For persistence, native key access, ciphertext records, enrollment/recovery envelopes or synchronization, read docs/architecture/private-inbox-storage.md, docs/architecture/private-product-sync.md, applicable privacy/sync companions, ADRs 0001, 0002 and 0005 and .patterns/product-sync-records.md where that retained typed boundary is involved. Keep provider credentials and decryption keys device-local; preserve native Keychain accessibility, non-synchronizing policy, file protection and Mac Data Protection Keychain requirements. Backend storage/transport must remain opaque and cannot decode Private Sync plaintext or fetch readable mail; retain only the operational metadata explicitly allowed by the owning decision. Verify authenticated account/record/schema/epoch binding, fresh nonces, malformed-envelope rejection, compare-and-set and atomic publication, concurrency/lock ownership, bounded pagination/retries, ciphertext-only fallback, tombstones and conflict preservation. Check crash and uncertain-write recovery before destructive cleanup or new key creation. Shared TypeScript does not receive native database encryption keys merely to open storage. The encrypted synthetic Inbox fixture is not a qualified general mail database and is separate from the Gmail body cache; keep those scopes distinct.

#### R6 — Mail, transport and delivery (conditional)

For providers, message identity, caches, attachments, rendering, search, pending actions or Outbox, read the applicable mailbox/messages/privacy companions and ADRs 0006, 0009 through 0017, 0028 through 0030, 0062 and 0069. Preserve mailbox-scoped identity and provider-native contracts against the current accepted launch scope in ADR 0069, without treating other prototype providers as launch commitments. Enforce authenticated secure transport, certificate/hostname verification and the restored TLS 1.2 minimum where applicable. Preserve local metadata search, bounded encrypted body caching, attachment consent/size/cancellation/storage boundaries, and sanitized isolated message rendering with the owning decision's explicit remote-content rules. A changed reader/remote-fetch path must check those decisions in full rather than infer consent or allow network access from a cache entry. Durable provider actions must retain their retry/cancellation and authorization-generation fences. For replacement sending, synchronize Drafts and encrypted assets with conflict preservation, keep Outbox delivery on the originating device, retain the default 10-second Undo Send window and require the content-free atomic Convex ownership claim before handoff to any launch provider. Offline queueing does not authorize provider submission; uncertain provider outcome must never trigger automatic resubmission. No independent helper, cross-device delivery takeover or alternate Convex-outage send path is a first-release requirement.

Review Outbox delivery text in `docs/outbox.md` and localized values under
`packages/localization/catalogs.bundle/` against `createOutbox` and Gmail's
`SendOutcome` mapping. Distinguish retryable definite refusals from uncertain
handoffs rather than promising one provider request; identify the required
Product Account service rather than peer-device connectivity; and describe
another device's retained claim without asserting it is currently sending.
Otherwise the interface misstates when delivery can proceed, stop or retry.

Provider-choice copy such as `onboarding.providers.other.detail` in
`packages/localization/catalogs.bundle/` must match the supported transport and
server capabilities in `docs/product/power-user-launch.md` and the owning provider
guide. Offering manual IMAP/SMTP setup does not establish universal server
compatibility; otherwise the chooser promises support for servers the native
adapter must refuse.

#### R7 — Assistance and notifications (conditional)

For AI/translation or notifications, read ADRs 0052, 0053, 0063, 0068 and 0072 and docs/architecture/product/assistance.md and applicable privacy/sync companions. Assistance is on-device, takes bounded already-local untrusted input, has no provider/backend/network/tool dependency, and never mutates source. Except for planned Catch Up Background Message Summaries and post-launch Mail Commitment Suggestions, it is explicitly invoked and returns an ephemeral preview. For Catch Up, verify device-local default-off enablement and body-cache storage, quota and removal lifecycle against ADR 0068; summaries never synchronize or reach a server. For Mail Commitments, read its product/architecture companions and ADR 0072: verify the separate device/Profile scan switch, encrypted device-local queue, lock/disable/source-loss lifetimes, reviewed admission and authored-record retention exception. Unaccepted outputs never synchronize; accepted records and minimal review decisions use opaque Private Sync. Preserve one-Profile ownership, reviewed moves, explicit lifecycle actions, conflict preservation and stale-write fencing without expanding launch scope.

Revalidate owner and input revisions; cancellation, staleness, refusal or unavailability must not mutate mail or Drafts and ordinary mail remains usable. Retain the separate translation boundary and capability/enablement checks.

Replacement new-Inbox notifications require permission and per-connection eligibility, exclude historical sync, default to generic content and require explicit opt-in for previews; device evaluation and backend-content privacy remain intact. Deferred categorization must not become a prerequisite for replacement notifications.

#### R8 — Host and workspace boundaries (conditional)

For mobile/Mac hosts, shared packages, native modules, bundles or dependency configuration, read ADRs 0059 and 0064, docs/architecture/expo-client.md, docs/architecture/macos-client.md and affected native/storage companions. Keep one root pnpm workspace/lockfile and its named host catalogs at the documented toolchain versions; do not force incompatible native renderers together. Shared application logic must not import React, React Native, Expo or native modules; hosts own views and adapters. Check real Metro bundle and autolinking boundaries, not just version declarations. AppKit owns Mac window identities, menus, focus routing and application lifetime; windows retain independent selection, closing the last window keeps the app active and explicit Quit stops execution. Replacement deployment floors remain iOS/iPadOS/macOS 27; prototype targets keep their own scope. Do not turn unavailable native qualification into a passed check or lower deployment targets.

- When changing `.dependency-cruiser.cjs` or its regression fixtures in
  `scripts/dependency-boundaries.test.mjs`, check the import specifier as well as
  the resolved destination against `packages/README.md`. An exported target must
  not exempt cross-package relative imports from the import-by-name convention;
  otherwise callers bypass export resolution and depend on the package's physical
  layout. Exercise both rejection of a relative import to an exported target and
  acceptance of a package-name import that actually resolves to that target,
  preserving same-package source and test-fixture imports. Review the enforcement
  configuration itself; a passing boundary lint cannot prove its rules implement
  the documented convention.

#### R9 — Effect and host execution (conditional)

Before reviewing TypeScript, read docs/agents/effect.md and, for services, effect-services.md; before reviewing Effect code read the installed node_modules/effect/AGENTS.md completely and follow its links. Read ADR 0065 and docs/architecture/agents/effect.md for scope. Decode every untrusted boundary with Schema and fail closed while preserving native security checks. Shared mail-core application logic and Convex actions calling external services use Effect; Convex deterministic queries/mutations keep Convex validators and plain TypeScript, and host React consumes framework-independent stores. Run once at the host/handler boundary, preserve the Convex configuration/async/fetch contract, own and dispose runtimes/resources, and serialize shared mutable work. Retain tagged errors and foreign causes for recovery but log only allow-listed diagnostics, never raw mail, tokens, account identifiers or foreign errors. Apply the service-constructor/layer conventions where services are changed. Respect documented lint exemptions and the dependency-free legacy harness; do not expand Effect adoption beyond the accepted scope.

`createLocalization.apply` in `packages/localization/src/index.ts` or another transition owning a snapshot and changing an external engine before publishing must account for rejection after that engine changes. Restore the previous engine state before rejecting, or reconcile the published snapshot through the owning failure contract; do not leave consumers observing contradictory state. Verify the failed transition through public actions, snapshot identity, subscriptions and a later retry, without assuming rejection implies that no side effect occurred.

#### R10 — Testing, native ownership and CI (conditional)

For tests, mock sessions, harnesses, qualification, workflows or operational changes, read ADR 0060, ADR 0049 Use a risk-weighted test portfolio, docs/agents/testing.md, native-validation.md, pull-request-babysitting.md and relevant architecture/qualification companions. Prefer real integration and E2E evidence for named failure risks; mocks/stubs and packaged synthetic journeys do not prove provider authentication, persistence, native bindings or live compatibility. Keep synthetic identities, external scenario/reset ownership and test-only production isolation; no production credential or reset backdoor belongs in mock testing. Preserve owned native resources and fail-closed cleanup, deterministic isolation and required release qualification. Retain coverage for privacy, identity isolation, encryption, data loss and duplicate delivery when retiring implementation; disabled legacy Swift CI is not a replacement-host merge gate. Preserve credential-free PR babysitter isolation and remote-CI policy; do not execute PR-controlled code outside the permitted sandbox or broaden permissions to make local validation pass.

For UI automation such as `tools/deberta-mac-spike/probe/SpikeProbe.swift` `run`,
tie completion to the action just started before accepting a ready/enabled
control. That control can already be enabled before dispatch; require evidence
of the new operation or its completed outcome, including fast operations whose
busy state polling can miss, or the probe can capture stale results or start
the next action before the previous one begins.

For evidence-driven runners such as `tools/deberta-mac-spike/probe/autorun.zsh`,
verify expected successful action identities as well as record counts before
returning success. Native failures can append records too; otherwise a failed
or partial matrix qualifies as complete. Keep intentionally cancelled lifecycle
records distinct from successful matrix results.

#### R11 — Documentation and review-rule changes (conditional)

For documentation, vocabulary, policy or .opencodereview changes, read docs/agents/domain.md and the affected authoritative sources. Keep vocabulary, observable requirements, architecture/rationale and historical evidence in their authorized-reader locations. Inventory every normative clause moved, rewritten or removed and record its destination or explicit reason; moving a requirement solely into reviewer-only content must not hide it from its implementer. Preserve privacy, recovery, migration and qualification scope clause by clause. Use full ADR filenames/titles where numbering collides. Update affected links and operational instructions, format and check local links/fragments; runtime or exported API changes need a changeset. The rule config and architecture/rule-coverage docs remain reviewer-only, while implementers may read their routing AGENTS.md. Maintain complete common-rule coverage: project entries are first-match, not compositional; merge_system_rule preserves only the embedded language rule. Order `rule.json` entries from most specific to the `**/*` fallback, keep every entry's `rule` a readable file under `.opencodereview/rules/` (an unreadable file silently resolves to no project rule), and keep the reference to this checklist as the first instruction of every path rule. Add a path-rule bullet only for a defect a linter, type checker or CI check cannot decide, name the file, helper or invariant it protects, and give the consequence. Validate rule resolution, owned documentation/tests selection and dependency/build/generated/secret exclusions with the real CLI when rules change. This checklist and its source routing must not silently rewrite an accepted decision.

- For product terminology renames, sweep current prose beyond the changed-file
  list, including configuration and tooling values in `.coderabbit.yaml` and
  repository-owned YAML, JSON and TOML. Review prose values even when an embedded
  language rule says to ignore them; otherwise active instructions retain the
  former term and propagate vocabulary drift. Classify remaining matches against
  the issue's exclusions for identifiers, paths, code comments, backend errors
  and historical records, preserving glossary `_Avoid_:` entries and approved
  exceptions. Exclude dependencies, generated artifacts and the `graft/` cache
  from the sweep.

#### R12 — Rule upkeep (conditional)

These rules improve from the reviews they take part in. Apply this section when the task answers pull-request review feedback, repairs a defect that an earlier review of the same code let through, or produced a finding you rejected as a false positive.

For each piece of validated GitHub review feedback (human, CodeRabbit, Codex or another review bot), each escaped defect and each rejected finding, decide whether the resolved rules should have changed the outcome. A real defect class that no rule names is a missing bullet: add it to the path rule that owns the code, naming the file, helper or invariant and the consequence. A finding the rules produced that the source or an accepted decision contradicts is a wrong bullet: narrow or remove it. A bullet that a linter, type checker or CI check now decides is retired, as is one that has gone stale with the code it names. Feedback that is a one-off, a style preference or already decided by tooling changes no rule.

Generalize from the instance to the defect class, keep the change within R11's rule-maintenance requirements, and validate it with `ocr rules check`. The same upkeep applies when OCR's embedded rules or rule format change with a version update, and when a new code area, package or host needs its own path rule. Report every rule change, and every candidate you declined with its reason, in the review report; an unimproved rule set after validated feedback it should have caught is itself a finding.
