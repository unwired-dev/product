# Repository documentation audit

Researched 2026-10-19 against `36f2a424f08ce811e1f27f6b409a931c8dc1b61e`. Scope: make implementation easier by
reducing repeated instructions, stale status claims and unnecessary process. This is a research report. It changes
no current rule, product requirement, review gate or release obligation.

## Recommendation

Start with contradictory feature instructions and duplicated workflow text. Then make separate decisions about
review depth, decision authority and mandatory skills. Keep privacy, native ownership and release evidence
explicit. Removing those requirements would change the product's guarantees, rather than simplify its
documentation.

The main problem is the number of places an implementer must reconcile, not the raw Markdown count. The tracked
baseline contains 535 Markdown files, including 271 changesets; `docs/` contains 193 files. The root agent guide is
268 lines and the implementation-review workflow is 587. These are inventory measurements, not implementation-time
measurements. No time saving is estimated.

## Prioritized findings

| Priority | Action              | Finding and implementation impact                                                                                                             |
| -------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| P1       | Revise              | Resolve contradictory Settings/composer instructions before they cause an implementation to restore obsolete save-on-navigation behavior.     |
| P1       | Merge               | Give workflow, skill selection and feature contracts one owner each. Root and skill entry points should route to that owner.                  |
| P1       | Decide, then revise | Make review depth and repeated review proportional to changed risk, while retaining independent final-artifact review.                        |
| P1       | Decide, then revise | Let implementers choose ordinary reversible implementation details without a mandatory three-model ballot.                                    |
| P2       | Revise              | Separate current requirements, current implementation and historical evidence so a dated research claim cannot look like today's plan.        |
| P2       | Revise              | Centralize validation commands and version ownership to distinguish diagnostic scans from CI gates.                                           |
| P2       | Merge or archive    | Remove superseded scheduling rules and live roadmap text from active reading routes; retain the decision/evidence record.                     |
| P2       | Revise              | Preserve the implementer/reviewer boundary while making every applicable implementation constraint available in the operational contract.     |
| P3       | Remove or merge     | Consolidate very small duplicated architecture companions and repeated routing boilerplate only after preserving their distinct requirements. |
| Keep     | Retain              | Native resource ownership, privacy/security constraints, real-versus-mock evidence, meaningful tests, stable ADR links and changesets.        |

### 1. Settings behavior has conflicting instructions

The Gmail guide says Account and the Command Palette open Settings without leaving an open composer, and explains
the retained Inbox on each host. [Source](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/gmail-inbox.md#L26-L37). The Draft guide still says opening Account
finishes recipient entry and waits for saving. [Source](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/drafts.md#L138-L146). The evaluation-editor guide says
Account first asks the save/delete question. [Source](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/draft-editor-evaluation.md#L62-L66).

The current mobile Account action dismisses the keyboard and opens Settings; the Mac action opens its separate
Settings window. Neither action calls the composer finish coordinator in these handlers. [Mobile
handler](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/apps/mobile/src/registration-gate.tsx#L171-L184), [Mac
handler](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/apps/macos/src/registration-gate.tsx#L168-L179), [Mac window
request](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/apps/macos/src/settings-window.ts#L31-L47). The qualification record identifies independent Settings
as issue #911 and explicitly defers interaction evidence. [Evidence
scope](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/qualification/expo-react-native-client.md#L12-L31).

Recommendation: remove Account from both older lists of actions that finish a Draft. Link those guides to the
Settings behavior owner. Keep saving requirements for actions that actually replace or close the editor. The
checked handlers support this correction; this audit did not execute a native interaction journey.

### 2. The same workflow is maintained in several places

The root guide repeats review models, sequence, ownership and repeat conditions. The implementation workflow
defines them again, and the issue skill reproduces the three handoffs and blocking rule. [Root
instructions](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/AGENTS.md#L36-L55), [workflow](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/implementation-review.md#L7-L31), [issue
skill](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/.agents/skills/implement-issue/SKILL.md#L112-L126). The issue skill already links to that workflow.
Keeping multiple executable versions increases the number of edits needed for a single process change.

Recommendation: keep the sequence, model policy, checkpoint procedure and review ownership solely in the workflow.
Keep issue selection and claiming in the issue skill, delivery in the babysitting guide, and skill selection in the
native component guide. Root `AGENTS.md` should retain a short task route, non-negotiable project constraints and
links. This is editorial consolidation; it need not change any gate.

The skill requirements also have a broad trigger. The root mandates observer and discovery work for every
development task and new domain, including a search/vet/install path. The native guide already gives task-specific
skill selection and says to load relevant references rather than add infrastructure. [Root
triggers](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/AGENTS.md#L164-L173), [scoped selection](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/native-components.md#L63-L85). The issue skill
calls for _material_ missing requirements to go to the panel; the workflow's trigger also includes competing
approaches. These scopes should be reconciled rather than described as identical. [Issue
skill](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/.agents/skills/implement-issue/SKILL.md#L57-L59), [panel
trigger](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/implementation-review.md#L374-L403).

Proposed replacement for the general discovery/observation trigger:

> Use installed skills that match the task and read only their applicable
> references. Discover and vet an additional skill when the task needs a
> capability the installed set does not provide. Use task-observer when the
> user requests workflow improvement or a repeated workflow problem warrants
> an observation.

This proposal changes mandatory process and requires a separate policy change. Toolchain rules and vetting still
apply to any actual installation.

### 3. Review cost follows the workflow category more than the artifact risk

Every implementation receives sequential OCR and thermo-nuclear review, with a third design review for user-visible
client changes. Required model/host unavailability blocks review. Even documentation-only tasks pass through the
thermo-nuclear procedure, which records that no code changed. [Sequence and
prerequisites](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/implementation-review.md#L7-L31), [documentation
handling](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/implementation-review.md#L289-L313). Later-reviewer edits require returning to OCR and
repeating later reviews; only OCR can reuse a valid incremental checkpoint. [Repeat
conditions](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/implementation-review.md#L162-L176), [incremental
scope](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/implementation-review.md#L405-L409).

The testing policy already distinguishes documentation, behavior, configuration and protected external seams. Its
documentation-only evidence is formatting, links, examples or other directly relevant checks. [Existing
proportionality rule](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/testing.md#L74-L89). This is not a logical contradiction: tests and review are
separate gates. It is an opportunity to use one risk classification for both.

Recommendation: retain an independent review, but make the extra passes explicit risk escalations. Keep full source
context wherever needed to assess a changed invariant. Preserve pinned comparisons, task-owned file coverage and
the rule that an unreviewed later edit cannot inherit an earlier pass.

Proposed replacement policy:

> Every implementation receives an independent review of the final task
> artifact. Documentation-only changes receive a documentation review and
> directly relevant checks. Changes to operational policy, examples or commands
> also verify those contracts. Code changes receive the applicable OCR standards
> and architecture review. A separate maintainability pass is required when
> requested or when the change adds a package, public interface or cross-module
> ownership boundary. Client-visible changes retain design review of the
> affected screens and states. After a fix, repeat reviews whose conclusions
> the fix can invalidate, covering the delta and its interactions. Record why
> other completed reviews remain valid. A review cannot attest to files or
> behavior it has not covered.

This changes current review policy. Do not apply it merely by treating this report as approval. Keep the current
review model rules unless a separate change explicitly revises them. Preserve CI and release qualification as
independent gates, including deferred native evidence.

### 4. The decision panel is a process prerequisite for routine choices

The panel covers missing requirements, product scope, competing approaches and architecture changes. It requires
binary ballots, three named models and a majority; after retries, unavailable votes can block the decision.
[Current policy](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/implementation-review.md#L374-L403). This can make a reversible local choice depend on
model access. The audit has not measured how often that occurs.

Recommendation: separate implementation discretion from authority to change a requirement. A model vote can advise
on a tradeoff; it cannot establish a new user preference or remove an explicit privacy constraint. Keep access
problems as unavailable prerequisites and respect explicit user limits.

Proposed replacement policy:

> The implementer chooses reversible implementation details within the issue's
> acceptance criteria and repository constraints. Record a material assumption
> and the check that verifies it. Use an advisory panel only for a disputed
> technical tradeoff that cannot be resolved from the code and requirements.
> Changes to product scope, user-visible behavior, privacy guarantees or an
> accepted architectural decision require an explicit authorized decision;
> model votes alone do not authorize them. Continue independent work while a
> required decision or unavailable prerequisite is pending. Existing Figma
> approval requirements remain in force.

This proposal changes decision authority and therefore needs explicit maintainer approval during a later policy
task. It does not relax any current panel rule.

### 5. Dated snapshots are mixed with present-tense claims

Several documents already distinguish requirements from evidence well. The power-user launch guide calls itself a
target, makes GitHub the completion owner and distinguishes implementation, deterministic tests and provider/native
qualification. Keep that pattern. [Launch scope](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/product/power-user-launch.md#L3-L11), [evidence
distinctions](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/product/power-user-launch.md#L160-L172).

Specific corrections are still needed:

| Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Recommended correction                                                                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Rewrite research says "The replacement is not implemented" after a scope update explaining its historical ticket graph. Current feature guides document multi-provider sending. [Research](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/research/expo-react-native-rewrite.md#L3-L38), [Outbox](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/outbox.md#L5-L19).                                                                            | Mark the entire interview/status body as a 2026-09-09 snapshot. Remove its present-tense role as a launch roadmap and route to the launch guide and GitHub. Do not reinterpret it as a claim that full replacement qualification is complete. |
| Platform qualification says "Evidence updated: 2026-10-04" but its first evidence section is dated 2026-10-17. [Header and newer section](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/qualification/expo-react-native-client.md#L3-L31).                                                                                                                                                                                                                                               | Distinguish the summary's review date from individual evidence dates. Keep commit-bound evidence entries and unavailable checks.                                                                                                              |
| Editor research says the default-off gate is follow-up #788; current feature guides describe that gate. [Research](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/research/editor-alternatives.md#L49-L59), [enablement](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/message-summaries.md#L36-L80), [Draft actions](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/draft-assistance.md#L61-L65). | Label the statement as the research-date baseline or update its implementation-status pointer. Preserve default-off consent.                                                                                                                  |
| Library research recommends trial/adoption, while the current manifest includes CSS parser libraries and `@exodus/bytes` as runtime dependencies. [Research ranking](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/research/third-party-library-opportunities.md#L19-L29), [manifest](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/packages/mail-core/package.json#L55-L73).                                                                     | Keep the dated assessment and add a disposition link to its implementation/decision. A dependency entry alone does not prove complete integration or native qualification.                                                                    |
| The archive index describes IMAP/Microsoft work as future and sends Microsoft work to #633; the launch guide identifies #633 as deferred Product Sign-In and mail as #634–637. [Archive routing](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/archive/README.md#L19-L25), [current provider scope](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/product/power-user-launch.md#L24-L48).                                                     | Remove live roadmap sentences from the archive index. Link to the launch guide instead.                                                                                                                                                       |
| Domain policy cites ADR 0059–0065 as supersessions while later active scope comes from the launch guide/ADR 0069. [Domain policy](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/domain.md#L19-L22), [launch owner](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/product/power-user-launch.md#L3-L11).                                                                                                                                | Route to the current scope owner instead of maintaining an incomplete numeric range. Keep explicit per-decision supersession for reviewers.                                                                                                   |

Active guides should identify hosts, implemented behavior, remaining acceptance criteria and qualification limits.
Keep dated evidence tied to its checked commit. Link current issue state instead of creating another live feature
registry.

### 6. Validation commands and version inventories need a single owner

The Expo validation block calls `pnpm fallow`, whose root alias is only `fallow --format json`. The README
documents `fallow audit --gate new-only`, while CI supplies the actual PR base SHA or push predecessor as its
comparison. These are different checks, even if each command succeeds. [Expo
commands](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/expo-client.md#L160-L168), [root alias](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/package.json#L13), [README
gate](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/README.md#L91-L108), [CI comparison](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/.github/workflows/ci.yml#L102-L109). Use one canonical
validation matrix and link it from host guides. Label diagnostic scans separately from blocking gates. For exact CI
parity, fetch and pin the actual target/event comparison rather than assume live `origin/main` is identical.

The Expo guide also manually repeats exact versions that manifests and catalogs own. Keep compatibility pairs,
intentional exclusions and upgrade constraints; link to or generate the inventory of current pins. This is a drift
risk, not a claim that the checked guide's versions are currently wrong. [Repeated versions and
constraints](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/expo-client.md#L31-L48), [compatibility pins](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/expo-client.md#L84-L101).

Scope graph-first routing to code discovery. For documentation tasks, start with the documentation index and use
graph queries only when source context is needed. The current root rule applies to any task; this audit's
documentation query returned unrelated code symbols. [Current trigger](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/AGENTS.md#L222-L230). No claimed token
or time saving from the graph CLI was used as audit evidence.

### 7. History and extraction leftovers still occupy active reading routes

The product messages guide includes historical cross-device scheduling rules, although it explicitly says the
replacement prohibits takeover. Its architecture companion retains the corresponding old mechanism. The archive
already has a Scheduled Send record marked historical for exactly that reason. [Active behavior
history](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/product/messages-and-delivery.md#L57-L75), [existing archive route](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/archive/README.md#L8-L17).

Recommendation: keep the current originating-device rule in the active contract, move remaining historical
scheduling detail to its historical owner and leave a stable route. Do not delete future Send Reminder requirements
that remain agreed, or treat moving them as a cancellation of their scope.

Some extracted companions contain almost no unique content. The privacy glossary companion has one cache-namespace
sentence, also stated in the product privacy companion. The identity glossary companion contains two short
implementation facts. [Privacy glossary companion](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/architecture/domain/privacy-and-sync.md#L8-L10), [duplicate
topic rule](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/architecture/product/privacy-and-sync.md#L47-L49), [identity
companion](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/architecture/domain/identity.md#L8-L14). Consolidate these into their existing reviewer topic owner
after checking all incoming links. Preserve any distinct detail, especially the statement that the backend stores a
credential digest rather than the credential. Do not flatten large, independently useful feature companions merely
to reduce file count.

Keep stable ADR filenames. The ADR index explicitly explains duplicate numbers and requires full titled links, so
renumbering would add churn without fixing implementation guidance. Add explicit applicability/supersession routes
where needed instead. [ADR numbering contract](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/adr/README.md#L7-L13).

### 8. Preserve the reading boundary without hiding acceptance criteria

Current policy excludes architecture, ADRs, research, qualification and archive from implementer reading and
searches. Operational guides must remain readable in full. [Reading
policy](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/implementation-review.md#L50-L88). The boundary is not a filesystem security barrier; the
workflow states that explicitly. It is an agent-context policy.

The split often works: Private Inbox storage exposes native custody and purpose-named operations, and Outbox
exposes atomic admission, durable claims, originating-device delivery and unknown-outcome safety. [Operational
custody contract](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/private-inbox-storage.md#L69-L82), [operational delivery rules](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/outbox.md#L124-L146). Do
not duplicate their full mechanism or rationale back into every guide.

The remaining risk is scope information that has to be reconstructed across feature prose, supersessions and
reviewer-only evidence. The architecture index explicitly says extracted passages retain their original scope;
extraction alone therefore did not reconcile current versus prototype requirements. [Extraction
scope](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/architecture/README.md#L13-L16). The domain policy acknowledges that some behavior notes still describe
the prototype. [Retained legacy content](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/domain.md#L35-L38).

Proposed replacement maintenance rule:

> Every active implementation requirement has one implementer-readable owner
> with its host and release scope. Architecture and ADRs retain rationale,
> mechanisms and historical decisions, and link to that operational contract.
> When extracting a passage, preserve its requirement and scope in the
> operational owner. A reviewer reports any missing requirement there rather
> than introducing it only as a late review finding. Qualification records
> retain full evidence; operational validation instructions name all still
> required release checks and their unavailable status.

Retain the existing reading restriction during editorial cleanup. Removing that restriction is a separate policy
choice; this report does not establish that it is necessary. No sampled sensitive rule is recommended for deletion.

## Safe cleanup order and acceptance checks

1. Correct verified contradictions and stale routes. Check the Settings clauses,
   #788 reference, qualification date and Microsoft #633 routing against the cited
   owners. Preserve limitations and do not infer issue completion from this audit.
2. Consolidate duplicated instructions without changing behavior. Create an
   old-rule-to-owner checklist, update all callers and check links/fragments.
   Root and issue skill should name no second version of the review sequence.
3. Reconcile historical feature passages separately. For each moved/deleted rule,
   record whether it is active, superseded, prototype-only or future. Preserve
   scope and stable links. Keep active privacy, delivery and data-retention
   constraints exactly once in the appropriate operational contract.
4. Submit the proposed process changes as explicit policy decisions. Compare a
   prose-only correction, a command/config change, a native security change and
   a UI change against the proposed review/decision rules. Each must have a clear
   owner, required evidence and unavailable-prerequisite outcome. Do not weaken
   the current rules before the policy change is authorized and reviewed.
5. Apply approved policy changes atomically to root, workflow, issue skill and
   affected enforcement/tests. Validate workflow and search/checkpoint contracts
   if those files change. A documentation-only cleanup needs formatting, links
   and examples; product tests remain required when product behavior changes.

Preserve the existing domain policy's one-owner requirement and explicit reason for every substantive deletion.
[Existing migration checks](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/domain.md#L57-L67). Keep the testing policy's evidence distinctions and named
failure risks rather than replacing them with a target document count. [Testing
admission](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/agents/testing.md#L46-L72).

## Coverage, reproducibility and limits

This audit used repository documents and the checked-in implementation as primary sources. It sampled operational
entry points, workflow/skills, domain routing, launch requirements, Gmail/IMAP/Outbox/Drafts/assistance/editor
guides, architecture companions, ADR routing, rewrite/editor/library research, qualification and the archive index.
Reviewer-only sources were read in the research review role; recommendations preserve their boundary until an
authorized policy change. This is not a line-by-line audit of every ADR, archive record or changeset.

Inventory can be reproduced without a package installation:

```sh
git ls-files '*.md'
git ls-files 'docs/*.md' 'docs/**/*.md'
wc -l AGENTS.md docs/agents/implementation-review.md
```

Count unique tracked paths from the Git output; exclude this newly added report when comparing to the baseline. The
baseline was clean. Graph queries for the documentation topic did not locate Markdown contracts; scoped document
reads supplied that evidence. Graph and scoped source inspection located the Settings handlers. Repository content
searches used `scripts/implementer-grep` for implementer-readable sources.

A local link scan covered 107 tracked, implementer-readable Markdown files,
excluding changesets. It found no missing relative-path candidates and no missing
headings among 249 checked fragment links. A separate check validated all 55 report
citation paths and source-line bounds. These checks do not establish that every
linked claim is current. Formatting uses the installed Oxfmt 0.71.0 from the shared
checkout; its configuration differs only in ignore patterns outside this report.

No live GitHub status, Figma frames, installed external skill changes, provider service, native runtime or CI run
was audited. Issue numbers here are repository documentation claims, not fresh assertions about open/closed state.
The report does not prove package adoption merely from a manifest, make a new product choice, establish release
qualification or assert measured implementation delays. Before deleting Swift operating instructions, confirm the
live cutover and any remaining operational use; current index still treats them as useful while the prototype
exists. [Current routing](https://github.com/unwired-dev/product/blob/36f2a424f08ce811e1f27f6b409a931c8dc1b61e/docs/README.md#L62-L83).
