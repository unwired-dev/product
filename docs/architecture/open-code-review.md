# Open Code Review architecture coverage

Reviewer-only under the [implementation and review workflow](../agents/implementation-review.md).
The [repository rule config](../../.opencodereview/rule.json) carries the architecture
checklist applied by the host reviewer during OCR delegation. The architecture
index, ADRs, patterns and topic companions remain authoritative. This migration
changes how review instructions are resolved, not an accepted decision or launch scope.

## Preserved responsibilities

The baseline is the implementation-review workflow and architecture index before
the rule migration, at commit `a39270a7e51c0240d39055d98d38829792c574ab`.
Every prior review obligation retains the owner below; the workflow no longer
carries a second architecture checklist beside OCR.

| Existing responsibility                                                                                                      | Resolved rule or retained operational owner                                                      |
| ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Read applicable guides, architecture index, domain policy and relevant companions                                            | R1; reading boundaries remain in the workflow and agent guides                                   |
| Read ADR 0059–0065 and affected earlier/later decisions; apply explicit supersession and preserve historical scope           | R1, with conditional source routing in R4–R10                                                    |
| Check applicable privacy, encryption, identity isolation, transport and delivery guarantees                                  | R4–R7; R1 requires the full applicable sources, including affected decisions not enumerated here |
| Review the entire pinned task against specification and standards; inspect collaborating modules and test coverage           | R1–R2; workflow retains the actual comparison and `code-review` handoff                          |
| Independently validate findings and fix confirmed issues, preserving unrelated work and affected documentation/tests         | R3; reviewer remains the fixing owner                                                            |
| Run appropriate checks, inspect and rereview the corrected result; refresh coverage after edits                              | R3; workflow retains OCR commands and ownership pause                                            |
| Report coverage, findings/dispositions, changed files, results, unavailable checks and decision blockers                     | R3; workflow also requires applicable rule-section and source dispositions                       |
| Extract architecture, update moved links and preserve every requirement/decision without leaking it to implementers          | R1 and R11; workflow retains reviewer ownership                                                  |
| Preserve replacement qualification and release scope, without treating prototype or mock evidence as proof                   | R1, R8 and R10                                                                                   |
| Keep OCR/host review evidence distinct from required CI                                                                      | R3 and R10; workflow retains the independent delivery gates                                      |
| Explicit OpenAI/Codex `gpt-6.1-sol`/`high` reviewer, no global/provider configuration changes, and paused implementer writes | Retained workflow spawn/ownership contract; rules do not select the model or alter host settings |

## Conditional source routing

The common sections R0–R3 apply to every task-owned artifact. Conditional sections
follow the changed behavior and its collaborators, not only a path prefix.
A cross-cutting change can require several sections. Record applicable sections,
source references and outcomes in the review; explain an exclusion or an
unavailable source/check. Do not infer completion from rule resolution.

| Rule section                             | Primary authoritative sources                                                                                                                                                                                                                    |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| R4: identity, authorization and recovery | [ADR index](../adr/README.md), especially 0061 and affected earlier identity/privacy decisions; registration, linking, identity and private-sync companions in the [architecture index](README.md)                                               |
| R5: encrypted storage and Product Sync   | [Private Inbox storage](private-inbox-storage.md), [Private Product Sync](private-product-sync.md), privacy companions, relevant ADRs and [typed record patterns](../../.patterns/product-sync-records.md) where applicable                      |
| R6: mail, transport and delivery         | Mailbox/messages/privacy companions, affected earlier mail/transport/rendering decisions and ADR 0062 via the [ADR index](../adr/README.md)                                                                                                      |
| R7: assistance and notifications         | [Assistance](product/assistance.md), privacy companions, ADRs 0052, 0053 and 0063 via the [ADR index](../adr/README.md)                                                                                                                          |
| R8: host and workspace boundaries        | [Expo](expo-client.md), [Mac](macos-client.md), affected native/storage companions and ADRs 0059/0064 via the [ADR index](../adr/README.md)                                                                                                      |
| R9: Effect and host execution            | [Effect conventions](../agents/effect.md), [services](../agents/effect-services.md), [architecture companion](agents/effect.md), installed Effect guide and ADR 0065 via the [ADR index](../adr/README.md)                                       |
| R10: testing, native ownership and CI    | [Testing policy](../agents/testing.md), [native validation](../agents/native-validation.md), [PR babysitting](../agents/pull-request-babysitting.md), mock/qualification companions and applicable testing ADRs                                  |
| R11: documentation and rule changes      | [Domain policy](../agents/domain.md), affected authoritative sources, [rule config](../../.opencodereview/rule.json) and [upstream rule format](https://github.com/alibaba/open-code-review/blob/main/pages/src/content/docs/en/review-rules.md) |

This routing is not an exhaustive decision inventory. R1 requires any affected
source beyond these starting points. Check retained Swift against its applicable
prototype decisions; apply explicit replacement supersessions to replacement
work. Deferred providers, Profiles and advanced features remain deferred unless
an authorized decision changes their scope.

## Rule matching and selection

OCR uses the first matching project entry and never combines entries, and one
entry resolves one rule. `rule.json` therefore orders its entries from most
specific to the `**/*` fallback, and each entry's `rule` names a Markdown file
under `.opencodereview/rules/`. OCR reads that file relative to the repository
root. An unreadable file produces only a `rule file not found` warning and no
project rule, so `pnpm test:tooling` checks that every entry's file exists.

[`rules/common.md`](../../.opencodereview/rules/common.md) carries R0–R12. The
fallback entry resolves it directly. Every path rule opens by requiring it, which
keeps the common and conditional sections in one file and applies them to every
task-owned artifact regardless of directory. A path rule adds the concrete
defects of one area:

| Entry order and pattern                                          | Path rule              | Embedded rule |
| ---------------------------------------------------------------- | ---------------------- | ------------- |
| `.opencodereview/**`, `**/*.md`                                  | `docs.md`              | Not merged    |
| `packages/contracts/fixtures/**`                                 | `contracts.md`         | Not merged    |
| `**/*.{test,spec}.*`                                             | `tests.md`             | Not merged    |
| Test, fixture and testdata directories, `**/*Tests/**`           | `tests.md`             | Merged        |
| `.github/**`                                                     | `workflows.md`         | Merged        |
| Named workspace and build configuration files                    | `workspace.md`         | Merged        |
| `scripts/`, host `scripts/`, Expo config plugins                 | `tooling.md`           | Merged        |
| `packages/mail-test-harness/**`                                  | `mail-test-harness.md` | Merged        |
| `packages/convex/**`                                             | `convex.md`            | Not merged    |
| `packages/contracts/**`                                          | `contracts.md`         | Not merged    |
| `packages/mail-core/**`                                          | `mail-core.md`         | Not merged    |
| Host TypeScript in `apps/mobile` and `apps/macos`                | `hosts.md`             | Not merged    |
| `native/**`, `apps/macos/macos/**`                               | `native.md`            | Merged        |
| `apps/unwired-mail/**`, `tools/swiftmail-provider-qualification` | `swift-prototype.md`   | Merged        |
| `**/*`                                                           | `common.md`            | Merged        |

`merge_system_rule: true` prepends the embedded rule selected for each file's
language. The embedded Swift, Objective-C, workflow and `package.json` rules
state real defect classes and stay merged. The embedded TypeScript rule prefers
`async`/`await` and `Promise.all`, asks for user-facing error text and repeats
what oxlint enforces; that contradicts the [Effect conventions](../agents/effect.md),
so Effect-governed TypeScript resolves its path rule alone. The embedded fallback
for Markdown is a generic code checklist and is not merged either.

## Research basis and transfer limits

Sources checked on 2026-10-04:

| Source                                                                                                                          | Practice used here                                                                                                  |
| ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| [OCR v1.12.11 rule format](https://github.com/alibaba/open-code-review/blob/v1.12.11/pages/src/content/docs/en/review-rules.md) | First-match path routing, an explicit embedded-rule merge choice, and selection/exclusion checks with the real CLI. |
| [CodeRabbit path instructions](https://docs.coderabbit.ai/configuration/path-instructions)                                      | Focused instructions for an area, with references to existing standards rather than another complete copy.          |
| [Sentry agent guide](https://github.com/getsentry/sentry/blob/master/AGENTS.md)                                                 | Area-specific source routing and diff-first review; avoid duplicate long instruction sets.                          |
| [Next.js agent guide](https://github.com/vercel/next.js/blob/canary/AGENTS.md)                                                  | Read local source guidance and choose tests that exercise the actual mode, fixtures and observable behavior.        |

The requested local T3 Code comparison used `~/git/github/t3code` at
`54084ae1e6c32809db040e4fa571c80fdf2d8ae4`. Its
[architecture overview](https://github.com/pingdotgg/t3code/blob/54084ae1e6c32809db040e4fa571c80fdf2d8ae4/docs/internals/overview.md),
[Effect service guide](https://github.com/pingdotgg/t3code/blob/54084ae1e6c32809db040e4fa571c80fdf2d8ae4/docs/internals/effect-services.md),
and scoped [Effect review](https://github.com/pingdotgg/t3code/blob/54084ae1e6c32809db040e4fa571c80fdf2d8ae4/.macroscope/check-run-agents/effect-service-conventions.md)
and [UI review](https://github.com/pingdotgg/t3code/blob/54084ae1e6c32809db040e4fa571c80fdf2d8ae4/.macroscope/check-run-agents/ui-consistency.md)
provide the comparison. That checkout has no `.opencodereview` configuration.
The transferable practices are shared state with platform adapters, explicit
wire compatibility, durable completion before publication, runtimes at execution
boundaries, tests of real collaboration, and findings scoped to introduced defects.
These support this repository's existing decisions; they do not create new ones.

T3 Code puts workspace execution and provider credentials on its server and uses
an event log for orchestration. This mail product keeps provider credentials and
decryption in native device code and uses an opaque Convex backend. Its rules do
not import T3 Code's event sourcing, Bun toolchain, Electron isolation strategy,
web UI primitives, review model settings or universal server-service structure.
This repository's accepted ADRs and Effect service constructor conventions win.

When writing another rule, scope it to an owned boundary, name the file, helper or
invariant, and give the reachable failure and its consequence. Preserve documented
exceptions and replacement/prototype scope. Remove a bullet that tooling already
decides; review changes to the enforcement itself. In particular, Inbox snapshots,
registration display data and the user-held Recovery Key setup presentation may
cross the local bridge, while native encryption keys and provider/device credentials
may not. Diagnostic and rejection channels retain their separate privacy limits.

Selection and resolution probes establish configuration behavior only. The new
rules have not been calibrated against historical pull requests or measured for
finding precision; this review checks their claims against source and accepted
decisions, without presenting that as calibration evidence.

The project entries take precedence over user-global rules and must not be
replaced by a CLI override during the required review.

Includes target repository Markdown and owned test names/directories. They bypass
both unsupported-extension and default-path filtering; they are not a whitelist.
Explicit dependency, build, generated, artifact and task-probe exclusions take
precedence. Binary and built-in secret protection remain non-bypassable. Review
all task-owned excluded artifacts through their appropriate boundaries, applying
the repository checklist directly without reading or exposing secret material.
Account for every preview entry, including duplicate paths with different status.

When changing rules, use the real CLI to check project discovery, each path rule, the common and
applicable conditional sections, embedded-language merging, owned docs/tests,
and dependency/build/generated/secret exclusions. Exercise workspace and pinned
range modes. This proves resolution and selection behavior, not architecture
correctness or integration qualification. The host reviewer still reads sources,
validates findings, fixes confirmed issues and records the evidence.

## Improving the rules

The rules are maintained from evidence, not written once. R12 in
[`rules/common.md`](../../.opencodereview/rules/common.md) makes the reviewer
revise them when a review cycle shows a gap:

- validated pull-request review comments from people, CodeRabbit, Codex or
  another review bot that named a defect class no rule covers;
- a defect that reached a pull request, CI or a release after an earlier review
  of the same code;
- a finding the rules produced that the source or an accepted decision contradicts;
- a check that a linter, type checker or CI job has taken over, or a bullet whose
  named file, helper or invariant has changed;
- an OCR version update that changes the embedded rules or the rule format, and
  a new package, host or code area that needs its own path rule.

The implementer hands these candidates to the reviewer under the
[workflow](../agents/implementation-review.md#improve-the-review-rules) without
reading the rules. The reviewer generalizes each one to its defect class, edits
the owning path rule, validates resolution with the real CLI and records the
change or the reason for declining it. This loop is the calibration the initial
rule set lacks; a rule change follows the same review and delivery gates as any
other change.
