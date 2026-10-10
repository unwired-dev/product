Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context, and apply its R11 in full. The rules below add the defects specific to Markdown, changesets and the review-rule files under `.opencodereview/`.

Documentation here is product truth that agents execute: an implementer follows the operational guides literally, and the reviewer treats ADRs and architecture companions as authority. A wrong sentence becomes wrong code.

#### Accuracy against the repository

- A command, script name, path, flag, version or environment variable that does not exist as written. Check it against `package.json`, the workflow files and the tree.
- A GitHub environment setup or recovery snippet in `docs/convex-deploy.md` or another operational guide that claims a branch-only secret boundary but only enables custom-policy mode and adds the allowed branch. Existing branch or tag policies survive those calls; verify that recreation or explicit policy deletion removes every unwanted policy before storing secrets, and that recreation restores deleted secrets. Otherwise a stale allowed ref can run its own workflow definition with deployment credentials.
- A CLI setup example in `docs/convex-deploy.md` or another operational guide that omits required arguments, assumes the wrong working directory or leaves an input-reading command without a documented value, file, pipe or interactive step. Check the installed CLI's help, package context, deployment selector and input behavior; otherwise following the example can fail or wait for unspecified stdin rather than configure the intended setting.
- A deployment setup guide treating every variable in a mixed root `.env.example` as a backend input. In `docs/convex-deploy.md`, check deployment variables against `packages/convex/convex/convex.config.ts` and keep local deployment selectors and host build settings at their owning boundary; otherwise operators configure the wrong environment. Link the backend schema rather than copying its variable list.
- Behavior described as shipped that the code does not implement, or planned replacement behavior stated in the present tense. Unavailable or deferred checks are described as deferred.
- Linked assessments in `docs/research/`, such as `blocknote.md` and `editor-alternatives.md`, prescribing incompatible initial evaluations or fallback conditions. Compare their recommendations and proposed next steps with the authorized evaluation scope; identify the governing recommendation and qualify superseded or conditional plans in each report. Otherwise readers can spend the first prototype effort on the wrong candidate or mistake a comparison baseline for an approved work item.
- A feature specification in `docs/*.md` with undefined first-use state or interaction targets, or conflicting with its owning requirements, general rules or exceptions. Trace reused behavior to `docs/product/` or its feature guide, check scope and explicit supersessions, and qualify rules or cross-reference exceptions; otherwise implementers invent behavior or receive incompatible contracts. Preserve existing behavior or report the conflict for an authorized decision.
- In `docs/catch-up.md`, missing or conflicting first-use and no-unseen behavior, seen-state lifecycle, or bubble and reader contracts. Check durable device-local seen-marker initialization, ownership, retention, cleanup and independence from provider read state against ADR 0019. Trace message order, Thread-versus-message actions and collapsed-category exceptions to the owning reader and Catch Up requirements; otherwise implementers reset or share a divider, retain orphaned progress or act on the wrong messages.
- A storage or isolation boundary in `docs/drafts.md`, `docs/private-inbox-storage.md` or another feature guide that omits or misassigns Apple versus TypeScript responsibility for encryption/key custody, owner/revision refusal, limits or lifecycle cleanup. Trace the native enforcement and the shared-store caller separately, including purge execution versus in-memory invalidation; otherwise later changes can target the wrong layer and bypass a protection. State the concise ownership requirement and link to the owning guide without copying implementation mechanisms or rationale.
- A Gmail organization summary in `docs/gmail-inbox.md` or a changeset calling every action a reader button, or promising pending intent remains until confirmation without accounting for permanent refusal and explicit discard. Check `MessageActions`/`OrganizeStatus` and `createGmailInbox` settlement/resolution: label checkboxes and Inbox Undo have different roles and locations, and terminal reconciliation removes pending intent. Wrong summaries misdirect accessibility use or misstate recovery behavior.
- A required test-count gate or suite membership changed while documentation still cites an older run as current or final-tree evidence, falsely qualifying the changed suite. Check every such claim against the owning test runner and cited result log; label earlier runs with their historical scope and cite a passing run for the changed suite, or mark that evidence deferred.
- A relative link or heading fragment that does not resolve, or a link left pointing at a moved section.
- A statement that restates what a config file or command already says, where the copy can go stale. Point to the source.
- Steps in a workflow guide whose file scopes, prerequisites, handoff instructions or completion gates contradict each other. In `docs/agents/implementation-review.md`, trace each reviewer's handoff through its assigned review pass, including instructions inherited through prompt reuse or shared responsibilities; otherwise a second run of the same pass can be accepted as two distinct required reviews. Check neighbouring steps and exclusion handling for procedures that cannot complete or can bypass a required pass.
- An `in progress` claim lifecycle in `.agents/skills/implement-issue/SKILL.md` or `docs/agents/issue-tracker.md` that omits cleanup when ownership ends, including PR merge or closure, or gives no recovery path for claims left by crashed runs. Check claim acquisition, selection filtering, own-claim continuation, authorized takeover and release together; otherwise reopened or interrupted issues remain excluded from future work.
- `docs/agents/implementation-review.md` allowing a reviewer or delegated child
  to retain a PR watcher, recurring task or write ownership after its final
  report. Check that later notifications require a new review handoff; otherwise
  a completed review thread can edit the shared checkout concurrently with the
  implementer and invalidate both reviewed artifacts.

#### Vocabulary

- A term from `GLOSSARY.md` or a topic glossary replaced by a synonym, a new domain term used without a definition, or a glossary entry changed outside `docs/agents/domain.md`'s policy.
- Product Sign-In, Trusted Device, Mailbox Connection and Product Sync used interchangeably; they are distinct and their difference carries privacy meaning.

#### Authority and placement

- Architecture, design rationale or internal implementation mechanisms written into an implementer-facing file (`AGENTS.md`, `README.md`, `docs/*.md`, `docs/agents/`, `docs/product/`, `docs/domain/`). They belong in `docs/architecture/` or an ADR; the implementer-facing file keeps setup, commands, validation, observable behavior and concise boundary-ownership requirements that its implementer must satisfy.
- A requirement that exists only in a reviewer-only file after the change. The implementer must still be able to read every requirement it has to satisfy.
- An accepted ADR edited to reverse its decision without a supersession note, or a new decision recorded outside an ADR. Use the full ADR filename where numbers collide.
- A prototype, historical or archived statement presented as a first-release requirement or as qualification evidence.
- An agent guide (`AGENTS.md`, `docs/agents/`) that contradicts the root guide's workflow, validation or triage instructions, or that adds an always-loaded line which only restates a linked document.

#### Changesets

- A changeset or feature note that describes only the preferred mechanism while omitting an implemented fallback that weakens the stated guarantee. Trace the owning helper, such as `PrivateInboxStore.fullSync(_:)`, and its failure branches; otherwise consumers can mistake best-effort behavior for an unconditional durability or availability promise.
- A changeset naming a package outside the workspace, a bump level that understates the change (a breaking exported type or wire change marked `patch`), or a summary that does not say what a user or consumer observes.
- A runtime behavior or exported API or type change in the task with no changeset. Documentation, tests and internal refactors may omit one.

#### Review rules (`.opencodereview/`)

- A `rule.json` entry placed after a broader pattern that already matches its files; the first match wins and entries never combine.
- An `include` pattern whose representative owned files resolve to the fallback or an unrelated path rule, skipping the intended checks. Verify selection and resolution with the real CLI, preserving documented exceptions such as contract fixtures.
- A `rule` path that does not exist or is unreadable. OCR warns on stderr and silently applies no project rule to those files.
- A path rule whose first instruction no longer requires `rules/common.md`, or a change to `common.md` that drops a responsibility listed in `docs/architecture/open-code-review.md`.
- `merge_system_rule` changed for an entry without checking the resolved text with `ocr rules check <path>`; the embedded TypeScript rule contradicts the Effect conventions and is deliberately not merged for Effect-governed code.
- A rule bullet that a linter or type checker already decides, that names no file, helper or invariant, or that gives no consequence. Such bullets produce noise and dilute the rest.
- Validated review feedback or an escaped defect in the task with no rule change and no recorded reason for declining one; see R12.
- An `include` or `exclude` change that hides task-owned source from review or admits dependencies, build output, generated files or secrets.

#### Leave to tooling

Markdown formatting and line wrapping belong to oxfmt.
