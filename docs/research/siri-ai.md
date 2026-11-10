---
status: research
---

# Siri AI Developer Preview assessment

Research date: **2026-11-09**. Interview updated **2026-11-10**. This note records
Apple documentation, confirmed interview decisions and proposals for later scope. It
contains no implementation approval or qualification evidence. Apple can change
the preview APIs and behavior. [Preview documentation][preview].

## Confirmed interview decisions

On November 9, the owner confirmed:

- **Q1:** "Plan a post-launch feature." Plan Siri AI integration alongside the
  existing App Intents work. It adds no requirement to the current launch.
- **Q2:** "Yes, search and open first." The first useful workflow finds mail and
  opens a selected message in Unwired. Reading, summarizing and Reply Draft
  creation are later candidates, not part of this first workflow.
- **Q3:** "Qualify all Apple clients together." Qualification covers iPhone,
  iPad and Mac in one milestone; a Mac-only pilot does not satisfy it. Preserve
  the existing iPhone/iPad Shortcuts plan.

On November 10, the owner answered **"yes to all"** for Q4–Q6:

- **Q4:** Separate per-device Siri authorization permits sender, subject, date,
  Profile/mailbox labels and opaque message references within the authorized
  Profile and selected mailboxes. Exclude bodies, snippets and attachment
  contents. Disclose that Siri may use cloud processing; Mail Assistance
  Enablement does not authorize Siri access.
- **Q5:** Search saved local metadata by default. Contact providers only when
  explicitly requested, and disclose incomplete coverage and unavailable
  mailboxes.
- **Q6:** Qualify English Siri requests on iPhone, iPad and Mac, including Czech
  interface and message content. Do not claim Czech Siri command support.

The owner also answered **"yes to all"** for Q7–Q8:

- **Q7:** A find request returns matching metadata. An explicit open request
  opens an unambiguous match directly; multiple matches require selection.
  Never guess or substitute another message.
- **Q8:** After iPhone, iPad and Mac qualify, release wherever Apple supports the
  integration, with a clear unavailable state elsewhere. Do not wait for Czech
  Siri or EU mobile availability. Existing Shortcuts remain independent.

EU mobile Siri availability currently blocks those end-to-end qualification
checks. Record them as deferred until they can run in a supported environment;
Mac and Shortcuts evidence do not establish mobile Siri qualification. Mobile
can qualify in a supported region without waiting for EU availability. The
owner confirmed shared understanding in Q9 and requested ticket planning. These
decisions approve the feature requirements, not runtime implementation.
[Product plan](../product/mail-capability-expansion.md#siri-ai-search-and-open).

The owner approved the five-ticket breakdown and requested publication on
November 10. The [published Siri delivery tickets](../product/mail-capability-expansion.md#siri-delivery-tickets)
record the two independent host paths, their existing App Intents blockers and
the joint release gate. Ticket publication and this research provide no runtime
implementation or native qualification evidence.

## Recommended fit for Unwired

The useful progression is **find a message → open it in Unwired → read selected
mail → prepare an editable Reply Draft**. Search and open is the confirmed first
workflow; later steps remain proposals. Use synthetic content to prove native
discovery and navigation across iPhone, iPad and Mac before exposing real mail or
adding writes. This does not change launch scope or authorize implementation.

Shortcuts and App Intents are already accepted follow-up requirements, with
per-device Mail Automation Grants, separately enabled action permissions and
recoverable Trash as the initial deletion limit. Their runtime delivery follows
the power-user launch. Siri AI could extend those adapters; it does not require
Unwired to implement an MCP server first or change the first Agent access
milestone. The existing automation tickets #1316–#1325 were still open when
checked on November 9. [Approved expansion](../product/mail-capability-expansion.md#invitations-automation-and-provider-rules),
[delivery order](../product/mail-capability-expansion.md#delivery-tickets),
[Mac search/read #1316](https://github.com/unwired-dev/product/issues/1316),
[Mac Draft creation #1317](https://github.com/unwired-dev/product/issues/1317),
[mobile search/read #1318](https://github.com/unwired-dev/product/issues/1318).

| Example request                            | Existing foundation                                                                                                                                                                                              | Proposed Siri boundary                                                                                                                                                                                                                                       |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| "Find the invoice from Oliver in Unwired." | Local sender/subject search and explicit provider search already exist. Local search covers saved metadata; online search reports partial failures. [Search guide](../gmail-inbox.md#searching-saved-mail)       | Search only an authorized Profile and selected mailboxes. Start with metadata results and disclose coverage; never silently broaden the scope.                                                                                                               |
| "Open that message in Unwired."            | Mobile targeted links preserve Profile and message identity and reject unavailable targets. Opening does not mark read. [Targeted navigation](../private-inbox-storage.md), [reader behavior](../expo-client.md) | First technical proof. Pass an app-resolved opaque reference, require current authorization, and reveal no body to Siri. Mac targeted navigation needs its own proof.                                                                                        |
| "Summarize this conversation."             | Explicit on-device message summaries exist; Catch Up remains planned. Existing summaries use bounded, already-local input. [Summaries](../message-summaries.md), [Catch Up status](../catch-up.md)               | Decide separately whether Siri receives message text or invokes existing local assistance and receives its output. Either exposes returned content to Siri and needs its own disclosure. Never claim whole-mailbox understanding from incomplete local data. |
| "Prepare a reply saying Tuesday works."    | Editable Drafts, Reply/Reply All and reviewed assistance exist. Provider-hosted Draft migration remains unimplemented in this checkout's guide. [Drafts](../drafts.md), [assistance](../draft-assistance.md)     | Create a separately authorized ordinary editable Draft with the correct Sending Identity. Preserve user edits, suppress duplicate creation and stop before Send in an initial Draft-only proposal.                                                           |
| "Archive these" or "send that reply."      | Provider organization and the durable Outbox already exist. [Mail actions](../gmail-inbox.md), [Outbox](../outbox.md)                                                                                            | Later work under the existing separate action grants. Sending must reuse Outbox admission, Undo Send and uncertain-outcome protection. A skill cannot bypass them.                                                                                           |

Do not present Catch Up, a mail MCP service, Spotlight integration or App Intents
as implemented. A source search under `apps`, `native` and `packages` found no
App Intents or Spotlight integration. The accepted Spotlight contract permits
metadata and opaque links only, excludes bodies and attachments, and requires
purging on lock and removal. Siri's broader indexing support does not expand
that contract. [Spotlight boundary](../domain/privacy-and-sync.md#language),
[planned Agent access](../product/agent-access.md).

Use a thin Swift App Intents adapter to call shared TypeScript mail and permission
logic. Keys and provider credentials remain native. Expo changes belong in its
native-generation plugins; the Mac adapter uses the separate React Native macOS
host. The Mac already has one shared mailbox runtime and notification-action
dispatch with its windows closed, but that does not prove Siri cold-start or
deadline behavior. Qualify that bridge before committing to background workflows.
[Native boundary](../adr/0067-keep-native-code-to-a-minimal-vault.md),
[Expo architecture](../architecture/expo-client.md),
[Mac architecture](../architecture/macos-client.md).

Mac is currently the accessible preview route for an EU user because Apple's
documented regional route allows Mac with a supported language. The owner chose
qualification across all maintained Apple clients; Mac availability does not
narrow that milestone. Mobile also remains part of the existing Shortcuts plan.
This workspace's selected Xcode and host macOS both reported **27.2** on November 9. No 27.3 compilation or Siri invocation was attempted; obtaining a qualified
27.3 environment remains a prerequisite. [Eligibility][support], [SDK][xcode].

## What changed and what can ship

Apple's November 3 announcement opens custom App Intents actions and content to
Siri AI, adds app skills for complex requests, and expands semantic-index support
beyond existing schemas. It describes customer delivery in a few months and
App Store submissions opening in spring, without a firm release date. Further
integration terms and usage policies are still forthcoming. Treat this as an
evaluation opportunity, not a production delivery commitment.
[November 3 announcement][announcement].

| Requirement        | Verified position on November 9                                                                                                                                                                                                                                                        |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SDK and toolchain  | Xcode 27.3 beta includes Swift 6.4 and the 27.3 platform SDKs; its host requires macOS Tahoe 26.6 or later. [Xcode release notes][xcode]                                                                                                                                               |
| New tool API       | `ToolIntent` is available from iOS 27.3, iPadOS 27.3, macOS 27.3 and visionOS 27.3. Its availability metadata excludes Mac Catalyst and does not list watchOS. This is narrower than availability of the Siri AI assistant itself. [ToolIntent][tool]                                  |
| Evaluation API     | `SiriEvaluations` starts at iOS/iPadOS/macOS/visionOS 27.3. [Framework documentation][evaluations]                                                                                                                                                                                     |
| Eligible hardware  | The integration requires an Apple Intelligence-capable device and an eligible region. [Preview documentation][preview]                                                                                                                                                                 |
| Permitted testing  | Development-profile builds run from Xcode and **internal** TestFlight testers. The preview functionality is unavailable to **external** TestFlight testers and App Store-installed versions, even when those builds contain the integration API. [Preview distribution rules][preview] |
| Simulator evidence | Apple explicitly requires a device rather than Simulator for manual app-skill verification. Spotlight behavior also needs physical-device validation. [Skills guide][skills], [verification guide][verification]                                                                       |

The maintained clients target OS 27, so a 27.3-only integration would need explicit
availability handling and would not establish support on the existing minimum
version. This is an implementation question, not permission to raise the minimum.
[Repository platform scope](../agents/native-validation.md), [API availability][tool].

## Languages, regions, and Czech users

The live Apple Support article, published November 5, lists **English, French,
Japanese, Korean, Portuguese, and Spanish**. Device and Siri languages must match
and be supported; the Apple Account must be in an eligible region. Siri AI is
unavailable on **iOS, iPadOS and watchOS in the EU**. EU Apple Accounts can use it
on **macOS and visionOS** with matching supported languages. Mainland China Apple
Account regions are currently excluded. Enrollment is through Siri Settings,
including privacy review and a model download; high demand can cause a waitlist.
[Current Siri AI setup and eligibility][support].

Czech is absent from both the current supported-language list and the announced
next additions, Traditional Chinese, Norwegian, Turkish and Vietnamese. There is
no published Czech availability date in these sources. Czech app localization
does not establish Czech Siri understanding. For a Czech/EU evaluation, a supported
language on Mac is the documented route; changing an iPhone's language alone
does not remove the EU restriction. Those last two sentences are inferences from
the eligibility rules. [Setup rules][support], [announced languages][announcement].

Siri AI excludes users under 13. Server-backed Apple Intelligence features,
including Siri AI, have variable daily limits, and Apple announces paid expanded
access in the future without a fixed allowance or price here.
[Announcement footnotes][announcement]. Do not promise unlimited service or infer
Siri quotas from a different Foundation Models API. [Usage terms][terms].

## Tool intents and schema restrictions

| Case                           | Documented rule                                                                                                                                                                                                                                                                                       |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Custom executable action       | Add `@AppIntent(.tool)` to a new or existing `AppIntent`; the macro adds `ToolIntent` conformance. [Integration guide][bringing]                                                                                                                                                                      |
| Existing Siri-supported schema | Do **not** add `.tool`. Adding it to a Siri-supported schema, such as `.messages.sendMessage`, is a **build error**. [ToolIntent][tool]                                                                                                                                                               |
| Shortcuts-only schema          | Use `@AppIntent(.tool, schema: ...)`, for example a Books or Journal schema. [ToolIntent][tool], [integration guide][bringing]                                                                                                                                                                        |
| Configuration-only intent      | A widget configuration intent with no action in `perform()` is unsuitable. A configuration intent that actually implements a custom action can qualify. [Integration guide][bringing]                                                                                                                 |
| Action granularity             | Prefer a single action whose parameters can be supplied by one request. Apple advises against promoting shortcut-only intermediate steps and side effects needing explicit user initiation, such as payment. This is selection guidance, not a documented ban on every write tool. [ToolIntent][tool] |
| Metadata                       | Supply intent title/description and parameter titles/descriptions. Describe formats, ranges and units when relevant. Parameters may be ordinary values or app-owned entities resolved by queries. [ToolIntent][tool]                                                                                  |

Schemas retain important constraints. Adopt a schema only for its intended
meaning. The macro validates required properties and missing ones cause build
errors. Apple Intelligence uses schema-defined properties; additional optional
properties are recognized only by Shortcuts. A custom tool is therefore a
different route from adding arbitrary extra Siri parameters to a standard schema.
[Schema integration guide][schemas-guide].

Mail is already a primary Siri schema domain. Its composing group requires
`createDraft`, the `draft` entity, `updateDraft`, `saveDraft`, and **`sendDraft`**.
Forwarding and replying groups also include `sendDraft`, plus the relevant
message entity and action. Apple says to adopt every schema in a selected
use-case group; omissions produce build **warnings**, not the missing-property
build errors above. A draft-only product scope cannot assume it satisfies the
standard composing group. This tension needs a product/API decision; it does
not authorize sending. [Mail domain and group table][mail],
[schema validation][schemas-guide].

`@AppEntity(.generable)` adds model-generated values to a `TransientAppEntity`.
Every property must be a plain value such as `Int`, `String` or `Date`, an
`AppEnum`, another `GenerableEntity`, or an array of those. Nongenerable properties
cause a compiler error. Generable values bypass an entity query; app-owned
nongenerable parameter entities use queries. **Proposal:** keep durable mail and
Profile identities app-resolved rather than treating generated identities as
authorization. [GenerableEntity][generable].

No exhaustive Siri-specific parameter-type matrix, tool-count limit, payload
limit, or cross-tool transaction guarantee was found in the reviewed preview
pages. General App Intents support does not prove every type works as a Siri AI
tool. Any selected signature needs an SDK build and end-to-end evaluation.

## Registration, configuration, and discovery

The published preview path is compiled Swift App Intents metadata and explicit
tool/entity exposure. The reviewed onboarding pages do **not** specify a separate
Siri AI developer registration, managed entitlement request, API key, remote tool
server, MCP registration, or preview-specific Info.plist key. This is the scope
of the documented procedure, not proof that every signing configuration will
work. Verify a minimal signed target before declaring setup complete.
[Preview setup][preview], [custom integration steps][bringing].

Do not import legacy SiriKit requirements without checking applicability.
Apple's `com.apple.developer.siri` entitlement page concerns iOS/watchOS Intents
extensions handling non-shortcut Siri requests; its Siri capability setup guide
explicitly discusses **SiriKit** and says that capability is unavailable on
macOS. Those pages do not establish that the new `.tool` integration needs that
entitlement. [Siri entitlement][siri-entitlement], [SiriKit configuration][sirikit-config].

App intents can live in the app, an extension, framework or Swift package.
Framework-owned declarations require an `AppIntentsPackage`, included by the
app's package through `includedPackages`. This is metadata discovery, separate
from choosing the runtime process. [AppIntent][appintent],
[AppIntentsPackage][intent-package].

For custom content, Apple describes Spotlight indexing, with
`EnumerableEntityQuery` as an alternative for unindexed entities and
`DynamicOptionsProvider` for parameter options. Onscreen context is explicit
entity association with views or user activities; the preview is not permission
to scrape all app state. Cross-app custom entities need transferable
representations. [Integration guide][bringing]. Spotlight's `IndexedEntity` and
property indexing keys determine what enters the app's search index.
[Spotlight guide][spotlight].

**Known macOS 27.3 beta issue, 191273925:** Siri cannot find third-party entities
donated to Spotlight unless they conform to a schema. The general custom-content
claim must be qualified by this platform-specific release note. Query-based
alternatives are documented generally, but their reliability as a workaround for
this issue is untested. [macOS release notes][macos-rn].

## Skills are guidance, not an execution policy

An app target supports one `Skills.skillsbundle`, named `Skills` in Apple's
template and added to Copy Bundle Resources. Each `Skills/<skill-name>/`
directory contains only `SKILL.md`. Names must be unique across the app,
extensions and embedded frameworks; duplicate selection is undefined.
[App skills guide][skills].

The format supports only `name`, `description`, and a Markdown body, with no
scripts, reference files or other frontmatter. `name` is 1–64 lowercase letters,
digits or hyphens, matches its directory, and has no leading, trailing or doubled
hyphens. `description` is nonempty, one line, at most 1,024 characters. The body
is limited to 10,000 characters and is read after Siri matches the metadata.
Xcode validates and compiles the bundle for system indexing. [Format rules][skills].

Apple explicitly says skills cannot enforce deterministic behavior and Siri
does not execute their listed tools sequentially. **Proposal:** use skills to
explain workflows; enforce consent, scope, revision checks and write admission
in application code. A sentence in a skill is not an authorization gate.
[Execution caveat][skills].

## Execution, background behavior, confirmation, and retries

The preview can act without the app's name while the app is foregrounded, a
Live Activity is active, or the Siri app conversation continues an app mention.
For background requests the overview requires mentioning the app. `ToolIntent`
also lists a relevant entity in search results as a tool-selection context.
Test both paths rather than assuming global selection for every request.
[Request contexts][preview], [tool selection][tool].

Execution remains in the app or an allowed extension, not in a developer-hosted
Siri tool service. `allowedExecutionTargets` selects eligible processes; the
default permits any available target. `supportedModes` separately selects
background, immediate foreground, dynamic foreground transition, or deferred
foreground before completion. `systemContext.currentMode` and
`canContinueInForeground` describe the actual runtime context.
[Execution targets][targets], [supported modes][modes].

**Unknown:** the preview pages do not specify a universal execution time budget,
durable job/continuation protocol, process survival guarantee, automatic retry
schedule, or exactly-once write contract. Background invocation does not prove
that the React Native runtime, encrypted store and shared TypeScript services
will be ready, or that mail work can continue indefinitely. A proposed adapter
must qualify cold launch, locked Profiles, cancellation and interruption.
[Runtime controls][targets], [repository native boundary](../adr/0067-keep-native-code-to-a-minimal-vault.md).

Siri can automatically confirm meaningful side effects, but may skip confirmation
for private entities. `OwnershipProvidingEntity` supplies shared/public ownership
information used in that decision. This is conditional behavior, not a promise
that every write receives an explicit confirmation. [WWDC26 confirmation chapter][confirmation-video].

Application code can call `requestConfirmation()` or its detailed overload
before unsafe/destructive work. It returns after confirmation and throws on
cancellation. Parameter confirmation is a separate boolean result, so it is
not interchangeable with confirming the whole action.
[Intent confirmation][confirm], [detailed confirmation][confirm-detail],
[parameter confirmation][parameter-confirm].

`IntentParameter.needsValueError(_:)` returns a `restartPerform` error that asks
for a value and re-performs the intent. Apple's migration talk says it restarts
`perform()` from the beginning; the asynchronous `requestValue` route continues
without that restart. **Proposal:** resolve and validate before mutation, then
use durable operation identity and existing write admission where needed. No
reviewed source establishes automatic deduplication after model replanning,
network uncertainty, user repetition or a process crash.
[Restart API][needs-value], [Apple migration talk][migration].

## Privacy, data exposure, and consent

Siri AI requests can run on-device or in PCC. Apple says PCC request data is not
retained or accessible to Apple. That statement is **not** a blanket zero-storage
promise for Siri: Apple retains usage metadata, Search requests have separate
retention/improvement behavior, and optional improvement enrollment collects
additional audio/text and conversation history. Siri app history can sync through
iCloud with end-to-end encryption. Settings also provide an Excluded Apps list
to stop app data use and actions. [Siri privacy notice, dated October 26][siri-privacy].

The reviewed preview API pages do not identify exactly which third-party entity
properties, tool inputs/results or transferred representations are sent to PCC
for each request. Nor do they promise an app-controlled on-device-only execution
switch for Siri orchestration. **Unknown:** per-operation transport boundaries,
history inclusion, retention after app revocation, and any guaranteed system
prompt before sending Unwired mail content. Do not infer those guarantees from
the general PCC statement. [Integration contract][bringing], [Siri privacy][siri-privacy].

| Integration                                        | Boundary supported by the cited Apple API                                                                                                                                                                                                                                                                             |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Unwired invokes `SystemLanguageModel`              | The model is on-device. An app creates its own `LanguageModelSession` and provides admitted inputs and tools. This does not confer control over a separate Siri session. [SystemLanguageModel][local-model], [session guide][local-session]                                                                           |
| Unwired invokes `PrivateCloudComputeLanguageModel` | An explicitly chosen server model, requiring network access, eligibility and a managed entitlement. `com.apple.developer.private-cloud-compute` is for this Foundation Models capability. It is not evidence of a Siri tool entitlement requirement. [PCC integration guide][pcc], [PCC entitlement][pcc-entitlement] |
| Siri invokes Unwired App Intents                   | Unwired explicitly exposes actions/content; Siri orchestrates the user request and may use on-device processing or PCC. Cross-app transfer is possible when entities provide compatible representations. Exact field-level routing is unresolved above. [Custom integration][bringing], [Siri privacy][siri-privacy]  |

Entity data is unauthenticated by default. Apple documents entity-wide and
property-specific `authenticationPolicy`, but property policy applies to Siri
responses; sensitive intent results need intent-level policy. `.internal`
property visibility excludes Siri, Shortcuts and other system experiences.
[Entity protection rules][bringing], [internal visibility][internal].

**Known iOS/iPadOS 27.3 beta issue, 190573761:** an entity or entity-property
authentication policy requiring unlock may fail to trigger unlock before Siri
displays the entity. A privacy evaluation must not treat that policy alone as a
proven lock boundary. [iOS/iPadOS release notes][ios-rn].

For Unwired, the owner confirmed separate per-device authorization and processing
disclosure for Siri's metadata-only first workflow. This does not classify it as
the existing MCP External Agent feature. On-device assistance consent, the separate planned
PCC consent, and an Agent Connection authorize different scoped behaviors.
Neither Apple's general Siri setup consent nor the use of PCC settles Unwired's
mail-specific disclosure, permission or retention contract.
[ADR 0073](../adr/0073-separate-external-agent-access-from-on-device-assistance.md),
[ADR 0075](../adr/0075-prefer-private-cloud-compute-for-separately-authorized-mail-assistance.md),
[assistance requirements](../product/assistance.md),
[Agent access requirements](../product/agent-access.md).

## Verification tools and proposed evidence

Apple describes **Siri Integration Advisor in Xcode** as feedback and suggestions
for intent/entity integration. The reviewed public pages do not document its
exact menu path, invocation automation, report format, coverage or release gate.
Do not present it as a security validator or a replacement for tests.
[Preview tooling description][preview].

`SiriEvaluations` scripts multiturn scenarios and checks called intents,
parameter values, found entities, loaded skills, onscreen entities, and response
text. Expectation comparisons are deterministic; Siri responses themselves vary,
so Apple recommends repeated scenarios. The framework integrates with
Evaluations and Swift Testing and reports transcripts/results in Xcode.
`SiriService.run(scenario:)` runs scenarios through Siri.
[Framework overview][evaluations], [SiriService][siri-service].

App Intents Testing verifies out-of-process invocation. Shortcuts, Spotlight and
real Siri exercise different behavior and none substitutes for the others.
[Verification guide][verification].

The following is **proposed evaluation scope**, requiring separate authorization
before any implementation or live-mail experiment:

1. Prove a minimal 27.3 integration in the maintained iPhone, iPad and Mac hosts
   using synthetic content. Verify metadata discovery, supported signatures,
   development signing, internal TestFlight, and the actual Advisor workflow.
   Exercise schema and untyped custom entity discovery separately because of
   the macOS known issue. Record unavailable platform checks as deferred.
2. Verify foreground, background and cold-start invocation with and without an
   app mention. Prove how a thin Swift adapter reaches shared TypeScript policy
   while keys and provider credentials remain native under ADR 0067. Do not
   duplicate mail policy in native code to make a demo work.
3. Try an explicitly selected synthetic message, ambiguous identity, missing
   body, locked Profile, revoked permission and stale entity. Verify query and
   result paths cannot bypass app scope or leak metadata through errors,
   snippets, spoken responses or the index.
4. Exercise cancellation, repeated requests, `restartPerform`, model replanning,
   interruption and unavailable foreground transition. Search/open must not mark
   mail read, send, create or edit Drafts, or discard existing work. For any later
   write feature, separately qualify confirmation, durable admission and duplicate
   suppression; skills text and Siri's automatic confirmation cannot prove them.
5. Record which content reaches system indexes, intent results, cross-app
   transfer and Siri history. Resolve field-level PCC handling with Apple if
   public docs remain insufficient. Define app consent and revocation before
   exposing real mail. Evaluate in supported languages without claiming Czech
   qualification or EU iPhone/iPad availability.

## Lifecycle check and final confirmation

Q1–Q8 settle the first feature's scope. No additional product-choice branch was
found in the lifecycle check below. The owner confirmed shared understanding in
Q9 and requested ticket planning. Runtime implementation remains separate.

The lifecycle review inherits the existing scoped automation boundaries. First
use requires per-device approval; upgrades and another device gain no implicit
authority. Disabling or narrowing a grant, locking a Profile, moving or removing
a mailbox, sign-out and observed device revocation must block subsequent queries,
target resolution, result replay and late results. Permission and ownership are
checked again before opening a message. Offline search reports saved coverage;
explicit online failures do not claim an exhaustive result. Cancellation and
retries cannot mutate mail, mark it read, discard an existing Draft or switch to
an unauthorized Profile. Siri approval does not enable Spotlight indexing.
These apply the existing [automation requirements](../product/mail-capability-expansion.md#invitations-automation-and-provider-rules),
[Profile/search boundaries](../private-inbox-storage.md), and
[Spotlight contract](../domain/privacy-and-sync.md#language); they introduce no
new permission for a body or mailbox write.

Reading, summaries and Draft/write schema decisions belong to later feature
scope. The first feature does not change the initial Agent access milestone,
which excludes sending and organization, or approve a Siri implementation.
[Confirmed Agent access contract](../product/agent-access.md).

## Evidence limits

Completed: live Apple announcement, current Support and privacy pages, official
App Intents and Siri Evaluations Markdown, relevant SDK release notes and Apple
video transcripts; comparison with the architecture index, ADR 0067, ADR 0073,
ADR 0075 and assistance/Agent access contracts. The current November 5 Support
page supersedes stale search snippets saying English-only.

Apple documentation HTML returned JavaScript shells. Their linked `.md` URLs
were fetched directly from `developer.apple.com` with Python `urllib`; mirrors
and third-party forum claims were not used as authority. Citations below point
to the readable canonical pages; append `.md` to documentation paths to inspect
the corresponding source text and availability metadata.

Not performed: SDK compilation, entitlement/signing inspection, Advisor run,
Siri Evaluations run, native interaction tests, traffic inspection, consent UX
design or provider-mail writes. All proposed runtime checks remain deferred.
No runtime code, glossary, ADR or dependency was changed. The interview records
the confirmed milestone, first workflow, metadata access, search coverage and
qualification scope, handoff and supported-market release policy above. Shared
understanding is confirmed; no runtime implementation was done.

[announcement]: https://developer.apple.com/news/?id=gdk2umrf
[preview]: https://developer.apple.com/documentation/appintents/siri-ai-developer-preview
[bringing]: https://developer.apple.com/documentation/appintents/bringing-custom-actions-and-content-to-siri
[tool]: https://developer.apple.com/documentation/appintents/toolintent
[skills]: https://developer.apple.com/documentation/appintents/orchestrating-complex-actions-with-app-skills
[evaluations]: https://developer.apple.com/documentation/sirievaluations
[xcode]: https://developer.apple.com/documentation/xcode-release-notes/xcode-27_3-release-notes
[support]: https://support.apple.com/en-us/127893
[terms]: https://support.apple.com/en-us/148587
[schemas-guide]: https://developer.apple.com/documentation/appintents/making-actions-and-content-discoverable-by-apple-intelligence
[mail]: https://developer.apple.com/documentation/appintents/app-schema-domain-mail
[generable]: https://developer.apple.com/documentation/appintents/generableentity
[siri-entitlement]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.siri
[sirikit-config]: https://developer.apple.com/documentation/xcode/configuring-siri-support
[appintent]: https://developer.apple.com/documentation/appintents/appintent
[intent-package]: https://developer.apple.com/documentation/appintents/appintentspackage
[spotlight]: https://developer.apple.com/documentation/appintents/making-app-entities-available-in-spotlight
[macos-rn]: https://developer.apple.com/documentation/macos-release-notes/macos-27_3-release-notes
[targets]: https://developer.apple.com/documentation/appintents/intentexecutiontargets
[modes]: https://developer.apple.com/documentation/appintents/appintent/supportedmodes
[confirmation-video]: https://developer.apple.com/videos/play/wwdc2026/343/?time=586
[confirm]: https://developer.apple.com/documentation/appintents/appintent/requestconfirmation()
[confirm-detail]: https://developer.apple.com/documentation/appintents/appintent/requestconfirmation(conditions:actionname:dialog:)
[parameter-confirm]: https://developer.apple.com/documentation/appintents/intentparameter/requestconfirmation(for:dialog:)
[needs-value]: https://developer.apple.com/documentation/appintents/intentparameter/needsvalueerror(_:)
[migration]: https://developer.apple.com/videos/play/tech-talks/10168/
[siri-privacy]: https://www.apple.com/legal/privacy/data/en/ask-siri-dictation/
[local-model]: https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel
[local-session]: https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models
[pcc]: https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute
[pcc-entitlement]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.private-cloud-compute
[internal]: https://developer.apple.com/documentation/appintents/intentvisibility/internal
[ios-rn]: https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27_3-release-notes
[siri-service]: https://developer.apple.com/documentation/sirievaluations/siriservice
[verification]: https://developer.apple.com/documentation/appintents/verifying-your-app-intents-implementation
