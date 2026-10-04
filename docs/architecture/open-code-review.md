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

The common sections R1–R3 apply to every task-owned artifact. Conditional sections
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

One `**/*` project entry supplies all common and conditional sections. OCR uses
the first matching project entry, so adding a specialized entry does not combine
it with the common entry. `merge_system_rule: true` retains the embedded rule
selected for each file's language; it does not merge two project entries.
The project entry takes precedence over user-global rules and must not be
replaced by a CLI override during the required review.

Includes target repository Markdown and owned test names/directories. They bypass
both unsupported-extension and default-path filtering; they are not a whitelist.
Explicit dependency, build, generated, artifact and task-probe exclusions take
precedence. Binary and built-in secret protection remain non-bypassable. Review
all task-owned excluded artifacts through their appropriate boundaries, applying
the repository checklist directly without reading or exposing secret material.
Account for every preview entry, including duplicate paths with different status.

When changing rules, use the real CLI to check project discovery, the common and
applicable conditional sections, embedded-language merging, owned docs/tests,
and dependency/build/generated/secret exclusions. Exercise workspace and pinned
range modes. This proves resolution and selection behavior, not architecture
correctness or integration qualification. The host reviewer still reads sources,
validates findings, fixes confirmed issues and records the evidence.
