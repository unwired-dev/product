# Implementation and review

One agent implements a change and owns it through delivery. One independent
reviewer checks it before the PR opens. CI and the automated PR reviewers
(CodeRabbit, Codex) follow under [PR delivery](pull-request-babysitting.md).

## Implement

1. Record `git status --short` and leave unrelated changes where they are. Use
   the task's open PR branch, otherwise its task branch, otherwise a new branch
   from the latest `origin/main`.
2. Write down the acceptance criteria and the checks that prove them. For UI,
   list every visible state you add or change with its Figma frame; that list
   feeds [design approval](#design-approval) and the [design review](#design-review).
3. Implement the smallest complete change and its tests under the
   [testing policy](testing.md). For code, run
   `mise exec -- scripts/pre-handoff.sh`; it ends with one `pre-handoff: PASS`
   or `FAIL` line. Documentation changes check formatting, links and any
   affected command or example.
4. Commit a local snapshot.

## Review

Start one reviewer in a fresh context, as a subagent. Give it the request or
issue, the acceptance criteria, the base commit to diff against, the checks
you ran with their results, and anything deferred. Give it the code, not your
conclusions about it.

Start the reviewer through T3 Code delegation (`delegate_task` with the `review`
role) on `gpt-6.1-sol` with `high` reasoning; pass both settings explicitly,
including when the implementer runs on another model. When T3 delegation or the
model is unavailable, the review is incomplete: do not fall back to native
subagents, the Codex CLI, another model or a self-review.

The reviewer reads the whole diff, the callers, owning modules and tests it
touches, and the architecture notes and ADRs for that area. It applies the
[checklist](#review-checklist) and returns findings ranked by severity, each
with `path:line`, the input or state that triggers it, and what goes wrong. The
reviewer reports; the implementer is the only writer in the checkout. A
subagent returns its report as text, and the implementer saves it with the
evidence; when a resumed reviewer reports again, its latest report replaces the
earlier one.

The implementer validates each finding, fixes the confirmed ones (including
every other instance of the same defect), reruns the checks and records a
disposition per finding for the PR. Run a second review when the fixes change
behavior beyond the findings themselves. When a second review still finds
blocking defects, stop patching: write down why the approach keeps failing,
then pick a different one or ask the user.

User-visible changes also pass the [design review](#design-review).

## Review checklist

Report a defect only when the change introduces or worsens it and the code you
read shows it is reachable, or, for documentation, when the code, a link or a
documented requirement shows the text is wrong. Defects in privacy, identity isolation, encryption,
data loss, Draft safety or duplicate delivery block the PR. Anything else
blocks only when it breaks a documented requirement or an item below.

CI already runs oxlint, oxfmt, `tsgo`, Effect diagnostics, Fallow, the changeset
gate and bundle checks; leave what they decide to them. A change that weakens a
check (a new `oxlint-disable`, `fallow-ignore`, lint override or skipped test)
needs a stated reason and the narrowest scope.

- **Requested behavior**: matches the issue and the requirements in
  [docs/product](../product/); adds no unrequested scope.
- **Identity**: Product Sign-In, Trusted Device proof, mailbox authorization and
  key possession stay separate. Accounts are never merged by email. Missing keys
  on an initialized account recover through trusted-device approval or the
  Recovery Key, never through new keys or an implicit reset.
- **Isolation**: provider identities, mailbox and thread state, restored
  credentials and keys stay scoped to their owning account, connection, device
  and deployment.
- **Privacy and storage**: provider credentials and decryption keys stay
  device-local. The backend stores and relays only opaque ciphertext and the
  metadata its owning decision allows. Logs and diagnostics carry allow-listed
  fields only: no mail content, tokens or account identifiers.
  [ADR 0077](../adr/0077-remove-friction-that-privacy-does-not-require.md) lets
  the person keep a copy of the Recovery Key in iCloud Keychain, which never
  reaches the backend; a change that implements it follows that ADR.
- **Data loss**: durable adoption comes before cleanup, and crash or
  uncertain-write recovery comes before destructive cleanup or new keys. Synced
  Drafts and records keep conflicts and tombstones. An encrypted-data reset or
  device cleanup leaves provider mail untouched.
- **Rendering and transport**: messages render sanitized and isolated; remote
  content loads only with per-message consent over the isolated cookie- and
  credential-free path. Connections require TLS 1.2 or later with certificate
  and hostname checks. Notifications show generic content unless previews are
  explicitly turned on.
  [ADR 0077](../adr/0077-remove-friction-that-privacy-does-not-require.md)
  changes three of these rules as its issues ship: previews become the
  notification default, remote images can be allowed for one sender, and a
  mail server endpoint entered by hand may use a pinned certificate. A change
  that implements one of them follows that ADR.
- **Delivery**: the Outbox sends only from the originating device, after the
  Convex ownership claim and the Undo Send window. Offline queueing does not
  authorize provider submission, and an uncertain provider outcome never
  triggers an automatic resubmission.
- **Assistance**: runs on device over bounded local input, with no network or
  backend dependency. Explicit actions return an ephemeral preview; summaries
  and unaccepted outputs never sync or reach a server. Cancellation, refusal or
  staleness leaves mail and Drafts unchanged.
- **Untrusted input**: decoded with Schema at the boundary and fails closed.
- **Boundaries**: shared packages stay free of React, React Native, Expo and
  native modules; packages import each other by name per
  [packages/README.md](../../packages/README.md); one pnpm workspace and lockfile.
- **Failure paths**: every async action settles on rejection, leaving the UI
  retryable. A new component, flow or guard covers the same states and
  failure paths as the existing one it parallels.
- **Tests**: prove the named behavior through public interfaces and run
  deterministically.

Turn a recurring defect into a test or lint rule rather than a longer checklist.

## Design approval

A request for visual design, or a look the Figma frames do not show yet, starts
in Figma. Implementing existing frames needs no new approval.

1. Read [DESIGN.md](../../DESIGN.md). In the
   [Unwired Mail — Design](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T)
   file, add or update the frames for every affected screen and state on the
   `macOS · …`, `iPadOS · …` and `iOS · …` pages, in Light and Dark, with
   DESIGN.md's tokens, the file's components and SF Symbols. Put proposals
   awaiting approval on the platform's Review pages, copying any approved frame
   they change so the approved design stays in place, and move approved
   sections to its Approved issue work page.
2. Ask the user to review: link each changed frame, say what changed and why,
   and list open questions.
3. Write design-dependent code only after the user approves; other work can
   proceed meanwhile. Record the approved frame links in the issue and the PR.

Figma steps need the Figma MCP server. When the current agent lacks it, run the
step in an agent that has it, such as a Claude subagent. Missing Figma access
blocks design-dependent work.

## Design review

Applies to anything people see or hear in a maintained client: screens,
components, styles, copy, icons, motion, notifications and accessibility labels.

1. Find the frames for every changed screen and state, in Light and Dark.
   Enumerate the file's pages (`figma.root.children` through `use_figma`)
   before concluding a frame does not exist.
2. Capture the result on the Mac host and on iPhone and iPad Simulators, in
   Light and Dark and in each size class the design shows, using mock mail
   sessions under [native validation](native-validation.md).
3. Compare layout, spacing, color tokens, typography, SF Symbols, Liquid Glass
   placement, copy and truncation, empty/loading/error/disabled states and
   accessibility (contrast, target size, labels). Differences the frames show
   deliberately between platforms are intended.
   Resize to window sizes the frame doesn't show: layouts hold, touch targets
   stay at least 44pt and content clears floating controls. When copy or
   accessibility labels change, update the native journey queries that find
   them; on macOS a disclosure needs the `button` role, not `header`.
4. Fix confirmed deviations and recapture. Where a frame differs from a product
   requirement, the requirement wins; list the difference in the PR as a design
   follow-up. Record a capture you could not take as deferred.

## Decisions

The implementer chooses reversible details within the acceptance criteria and
records material assumptions. Changes to product scope, user-visible behavior
beyond the request, privacy guarantees or an accepted ADR need the owner's
decision: present the concrete choice and continue independent work while it
is pending. Credentials, accounts, devices and paid services are prerequisites
to request, not choices to make.
