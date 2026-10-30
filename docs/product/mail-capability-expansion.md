# Mail capability expansion

Status: requirements confirmed by the owner on 2026-10-25 after the complete
interview, a source/backlog audit and two advisory interviews with Claude Opus
5.5. The owner confirmed shared understanding and approved the complete
46-ticket breakdown, formats and blocking dependencies on 2026-10-25.
This document records accepted requirements, not implementation or qualification.

## Confirmed direction

- Keep the accepted [power-user launch](power-user-launch.md) unchanged. New
  additions are follow-up work; existing launch gaps retain their current owners.
- Explore every gap and candidate identified by the audit and advisory interviews.
  All candidates are wanted for the product, including those an adviser suggested
  deferring or narrowing. Advice does not remove an owner-requested capability.
- Explore forgotten-attachment confirmation first among genuinely new additions.
- Make sign-out and Mailbox Connection removal confirmations explain known queued
  messages and uncertain delivery outcomes held on this device.
- Do not add the proposed 14-day primary-client trial or fallback diary. Existing
  provider, native, accessibility and performance qualification remains required.

The current individual, personal/work, multi-mailbox audience and existing privacy
and authorization contracts remain the baseline. The confirmed
[Mail Commitments](mail-commitments.md) and [Agent access](agent-access.md)
requirements remain in place. Exploration of new automation does not silently
expand the first Agent access milestone.

## Confirmed behavior

The owner accepted Q5–Q16 and Q17–Q29 on 2026-10-25. These requirements apply to
the follow-up expansion and do not add launch gates.

### Send warnings

- A [Forgotten Attachment Check](../domain/messages-and-delivery.md#language)
  inspects authored subject/body text, excluding identified quoted correspondence
  and signatures. A promised file requires a file Attachment; an Inline Image or
  logo alone does not satisfy it. The person can choose **Send Anyway**.
- Recipient and Sending Identity warnings use explicit, configurable Mail Profile
  settings for changed reply identity, added recipients, external domains and
  large Reply All. The warnings are overridable. Cross-Profile sending remains
  forbidden regardless of a warning override.
- The Forgotten Attachment Check starts enabled, with a per-Profile control and
  English/Czech phrase coverage. Recipient/identity warnings remain off until
  configured.
- Offer an optional Work preset covering changed reply identity, added
  recipients, recipients outside explicitly configured domains, and Reply All
  exceeding 10 recipients. Every condition and the recipient threshold is
  editable; the preset does not infer the person's organization boundaries.
- Resolve warnings before delivery authorization. Check at Send, Schedule and
  changes to scheduled content. An unattended operation needing confirmation
  returns **Needs attention** and preserves editable content; it does not wait
  for a dialog at delivery time.

### Leaving a device or mailbox

- Before sign-out or Mailbox Connection removal, explain the known local queued
  sends, unknown delivery outcomes and pending mailbox changes affected by the
  operation. Offer **Review Work** and **Continue Removal**.
- Continuation does not require sending first and cannot turn an uncertain
  handoff into permission to resubmit. Describe actual local effects rather than
  claiming that a synchronized copy or another Delivery Owner exists.

### Mail work status and Focus

- Provide Profile-scoped status across the user's Trusted Devices using minimal
  encrypted status reports. Show when each device last reported and distinguish
  unknown or stale state from current local knowledge.
- Viewing reported work does not transfer delivery ownership. A status report is
  not proof of remote device liveness.
- Synchronized reports include work types, counts, due times, status, owning
  device and report time. They exclude message subjects, bodies and recipient
  addresses.
- Apple Focus narrows notification eligibility without switching the active
  Profile, changing open mail or Drafts, or overriding quiet hours and existing
  notification switches.
- Each device follows its own operating-system Focus and keeps its Focus mapping
  local. Unwired does not propagate an active Focus through Private Sync. Apple's
  own Focus synchronization may still affect each device's operating-system state.

### Sender evidence and attachment search

- Explain unfamiliar sender addresses, suspicious Reply-To differences and
  trustworthy provider authentication evidence without declaring a message safe.
  These signals do not automatically block or delete messages.
- Familiar-sender warning dismissals apply to the exact name/address pairing in
  its Profile. They do not suppress new Reply-To differences or authentication
  failures and do not declare a sender safe.
- Attachment content search and OCR require separate opt-in. Index downloaded or
  explicitly selected files within their Mail Profile; do not download unseen
  attachments solely to improve results. Disclose incomplete coverage.
- Indexing consent is separate on each device and Profile. The index and its
  permission remain local; enabling one device does not enable another.
- Extracted text may survive routine cleanup of its temporary preview file,
  encrypted within a bounded index. Explicit removal of indexed content,
  disabling indexing, source deletion and applicable account/connection removal
  purge the derived content. Surviving preview cleanup does not authorize
  permanent retention or bypass existing removal and Profile Lock boundaries.
- Initial content search covers text, PDFs and supported images/scans, with OCR
  where supported. Other formats initially remain searchable by filename and
  metadata. Office content extraction remains follow-up work.

### Invitations, automation and provider rules

- An [Invitation Response](../domain/organization.md#language) is independent of
  adding an event to Calendar. Accept, Maybe and Decline are deliberate responses.
  Calendar integration remains optional, with separately authorized access and
  explicit handling of updates and cancellations.
- Associate organizer updates and cancellations with the existing event and
  present proposed Calendar changes for review. Do not silently modify Calendar
  or create a duplicate event for an update.
- Future automation uses narrowly scoped
  [Mail Automation Grants](../domain/agent-access.md#language). Sending,
  organizing and deleting are enabled separately. Once explicitly authorized,
  actions may run within their grant without repeated prompts. This requirement
  does not expand the first Agent access milestone.
- Automation grants require explicit approval independently on each device.
  Reusable configuration does not convey authority to another device.
- Initial automation deletion authority permits recoverable moves to Trash only.
  Permanent erasure, expunge and emptying Trash require a separate future
  permission.
- [Provider Mail Rules](../domain/organization.md#language) are initially
  read-only and clearly distinct from editable device-run Mail Rules. Request
  additional provider access when needed and explain unsupported providers.

### Languages and individual delegation

- English and Czech are the first interface languages to qualify, with additional
  catalogs following later. Incoming message decoding must not depend on which
  interface language the person selected.
- Shared/delegated mail initially serves an individual accessing delegated
  mailboxes. Team assignment, shared-inbox collaboration and CRM remain separate
  expansion decisions and do not enter this scope implicitly.
- Begin delegated-mail delivery with Microsoft 365 and qualified IMAP servers.
  Gmail delegation remains planned until a supported device-authorized path is
  established. Preserve device-local credentials and the existing backend
  privacy boundaries.

## Existing gaps and their owners

The audit inspected maintained Expo and React Native macOS source at
`ab769b9b5f319330fec467ef181f687ee9f4f833`, current feature guides, all 200 open
GitHub issue bodies and all 490 closed issue titles available on 2026-10-24.
These are dated source/backlog observations, not native or provider test results.
Closed Swift prototype tickets do not establish replacement support.

| Gap                                                                                | Existing work                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Complete mailbox navigation, unified folders and historical metadata backfill      | [#845](https://github.com/unwired-dev/product/issues/845), [#1004](https://github.com/unwired-dev/product/issues/1004), [#1005](https://github.com/unwired-dev/product/issues/1005), [#1006](https://github.com/unwired-dev/product/issues/1006), [#1007](https://github.com/unwired-dev/product/issues/1007), [#1008](https://github.com/unwired-dev/product/issues/1008), [#1009](https://github.com/unwired-dev/product/issues/1009) |
| Complete conversations and sent/received history across providers and hosts        | [#846](https://github.com/unwired-dev/product/issues/846)                                                                                                                                                                                                                                                                                                                                                                               |
| Whole-history metadata search, downloaded-body search, coverage and Saved Searches | [#847](https://github.com/unwired-dev/product/issues/847)                                                                                                                                                                                                                                                                                                                                                                               |
| Keep Offline, attachment retention and storage controls                            | [#848](https://github.com/unwired-dev/product/issues/848)                                                                                                                                                                                                                                                                                                                                                                               |
| Full keyboard navigation, recoverable bulk actions and undo                        | [#849](https://github.com/unwired-dev/product/issues/849)                                                                                                                                                                                                                                                                                                                                                                               |
| Recipient completion, Sending Identities, aliases, signatures and Mail Templates   | [#850](https://github.com/unwired-dev/product/issues/850)                                                                                                                                                                                                                                                                                                                                                                               |
| Thread Snooze and reply-aware Follow-Up Nudges                                     | [#851](https://github.com/unwired-dev/product/issues/851)                                                                                                                                                                                                                                                                                                                                                                               |
| Deterministic device-run Mail Rules and visible catch-up                           | [#852](https://github.com/unwired-dev/product/issues/852)                                                                                                                                                                                                                                                                                                                                                                               |
| Quiet hours and sender/rule notification filtering                                 | [#853](https://github.com/unwired-dev/product/issues/853)                                                                                                                                                                                                                                                                                                                                                                               |
| Default mail handling, sharing, drag/drop, printing and exact message export       | [#854](https://github.com/unwired-dev/product/issues/854)                                                                                                                                                                                                                                                                                                                                                                               |
| IMAP Reply, Reply All and Forward                                                  | [#1023](https://github.com/unwired-dev/product/issues/1023)                                                                                                                                                                                                                                                                                                                                                                             |
| Microsoft messages exceeding the audit-time 3 MB MIME limit                        | [#917](https://github.com/unwired-dev/product/issues/917)                                                                                                                                                                                                                                                                                                                                                                               |
| Ordinary mobile delivery during permitted background execution                     | [#1260](https://github.com/unwired-dev/product/issues/1260), [#1261](https://github.com/unwired-dev/product/issues/1261)                                                                                                                                                                                                                                                                                                                |
| Native Draft-exit protection, crashes, navigation and typing responsiveness        | [#778](https://github.com/unwired-dev/product/issues/778), [#1174](https://github.com/unwired-dev/product/issues/1174), [#1217](https://github.com/unwired-dev/product/issues/1217), [#1228](https://github.com/unwired-dev/product/issues/1228), [#1048](https://github.com/unwired-dev/product/issues/1048)                                                                                                                           |
| Mail Profile management, isolation, relaunch writes and independent iPad windows   | [#922](https://github.com/unwired-dev/product/issues/922), [#1038](https://github.com/unwired-dev/product/issues/1038), [#1039](https://github.com/unwired-dev/product/issues/1039), [#1040](https://github.com/unwired-dev/product/issues/1040), [#1188](https://github.com/unwired-dev/product/issues/1188), [#1200](https://github.com/unwired-dev/product/issues/1200)                                                              |
| Aggregate synchronization overlay and per-connection detail                        | [#1155](https://github.com/unwired-dev/product/issues/1155)                                                                                                                                                                                                                                                                                                                                                                             |
| Real-provider and packaged-native qualification, including protected test access   | [#855](https://github.com/unwired-dev/product/issues/855), [#1103](https://github.com/unwired-dev/product/issues/1103), [#1104](https://github.com/unwired-dev/product/issues/1104)                                                                                                                                                                                                                                                     |

Reuse those issues rather than creating duplicate feature tickets. Reported
native defects above were not reproduced during the discovery audit.
Since the audit, maintained Microsoft sending added a larger-message path; see
[the current Microsoft sending guide](../microsoft-mail.md#sending). Its real
Graph behavior remains a release check. The audit entry does not describe the
current implementation limit or establish completed provider qualification.

## Complete candidate inventory

Each row remains wanted. Confirmed behavior above owns settled requirements;
identify any remaining material owner choice individually. Delivery and
qualification work are distinct from unanswered product questions.

| Candidate                                    | Confirmed scope and remaining specification work                                                                                                  |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Forgotten Attachment Check                   | Enabled by default; English/Czech; actual-file requirement; content-bound override; checks at Schedule and scheduled-content changes              |
| Recipient and Sending Identity warnings      | Explicit Profile configuration; optional editable Work preset with a greater-than-10 Reply All threshold                                          |
| Locally held work before sign-out or removal | Review or explicitly continue; actual local consequences; no forced send or duplicate uncertain handoff                                           |
| Cross-device mail-work dashboard             | Minimal encrypted status metadata and timestamps; no message content or ownership transfer                                                        |
| Muted Thread in maintained clients           | Existing suppression meaning retained; delivery and post-launch sequencing tracked in [#1301](https://github.com/unwired-dev/product/issues/1301) |
| Apple Focus integration                      | Notification-only, device-local mapping; existing notification controls remain authoritative                                                      |
| Sender identity and authentication evidence  | Informational signals; exact-pair familiar-sender dismissals do not hide new Reply-To/authentication warnings                                     |
| Attachment finding and content search/OCR    | Device/Profile opt-in; local bounded index; retained extracted text with explicit purge boundaries; text/PDF/image initial formats                |
| Invitation lifecycle                         | Deliberate RSVP independent of optional Calendar; reviewed changes associated with existing events                                                |
| Apple Shortcuts and App Intents              | Per-device scoped action grants; unattended warnings return Needs attention; deletion means recoverable Trash initially                           |
| Provider Mail Rule inspection                | Read-only; provider-specific consent and capability; detailed slices reuse verified API facts                                                     |
| International mail completeness              | English/Czech UI and attachment phrases initially; decoding independent of UI; later catalogs and format/language qualification remain tracked    |
| Individual shared/delegated mailboxes        | Microsoft 365 and qualified IMAP first; Gmail authorization path remains unverified; no implicit team/CRM scope                                   |

Existing link destination confirmation and URL warning signals are already
implemented. Sender evidence extends those protections; it does not rediscover
them.
The existing [Muted Thread definition](../domain/organization.md#language) and
[behavior](organization.md#mute-and-blocked-senders) had no dedicated open
replacement slice identified by the audit; [#1301](https://github.com/unwired-dev/product/issues/1301)
now owns that follow-up. The mention of a muted subject in
[#807](https://github.com/unwired-dev/product/issues/807) describes typography,
not Thread muting.

## Already-planned capabilities to retain

- Scheduled Send and Send Reminders: [#659](https://github.com/unwired-dev/product/issues/659),
  [#1262](https://github.com/unwired-dev/product/issues/1262), [#1263](https://github.com/unwired-dev/product/issues/1263), [#1264](https://github.com/unwired-dev/product/issues/1264) and
  [#658](https://github.com/unwired-dev/product/issues/658).
- Categorization, custom Categories, bounded historical categorization, Profile
  Lock/Quiet, cleanup, unsubscribe, exact sender blocking and contact/calendar
  suggestions: [#648](https://github.com/unwired-dev/product/issues/648), [#649](https://github.com/unwired-dev/product/issues/649), [#650](https://github.com/unwired-dev/product/issues/650), [#651](https://github.com/unwired-dev/product/issues/651), [#652](https://github.com/unwired-dev/product/issues/652), [#653](https://github.com/unwired-dev/product/issues/653), [#654](https://github.com/unwired-dev/product/issues/654), [#655](https://github.com/unwired-dev/product/issues/655), [#656](https://github.com/unwired-dev/product/issues/656), [#657](https://github.com/unwired-dev/product/issues/657).
- [Catch Up](../catch-up.md) and Background Message Summaries.
- [Mail Commitments](mail-commitments.md) and [Agent access](agent-access.md).
- Existing deferred Spotlight, Android/Windows, bulk mailbox import/export and
  shared/delegated-mailbox directions remain visible for scope exploration.
  Their earlier exclusion from the Apple launch remains unchanged. Individual
  delegation is included in this expansion; team/shared-inbox/CRM work remains
  separate.

## Interview progression

### Verified prerequisites

- Current Drafts separate authored content, quoted correspondence, file
  Attachments and Inline Images. They do not yet have a dedicated signature
  field. A phrase check cannot reliably recognize a signature or correspondence
  pasted into the authored body. Signature work remains part of
  [#850](https://github.com/unwired-dev/product/issues/850); see
  [current Draft behavior](../drafts.md).
- Current sign-out and mailbox-removal confirmations are generic. Local Outbox
  states and pending provider changes can be inspected, but the Draft snapshot
  does not prove that each Draft has a synchronized copy elsewhere. Removing a
  Mailbox Connection and purging this device's Product Account have different
  effects; the warning must describe the actual operation.
- Apple documents [Focus Filters](https://developer.apple.com/documentation/appintents/setfocusfilterintent)
  on iPhone, iPad and native Mac. Background handling involves native extension
  integration; platform API availability does not establish maintained-host
  implementation.
- Gmail's [filter listing API](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.settings.filters/list)
  accepts the existing `gmail.modify` grant. Microsoft Graph's
  [Inbox rule listing](https://learn.microsoft.com/en-us/graph/api/mailfolder-list-messagerules?view=graph-rest-1.0)
  requires the additional `MailboxSettings.Read` permission. IMAP access alone
  does not establish a provider's [ManageSieve](https://www.rfc-editor.org/rfc/rfc5804.html)
  support or authorization.
- Saving a reviewed Calendar event does not implement invitation responses.
  [iTIP](https://www.rfc-editor.org/rfc/rfc5546.html) distinguishes attendee
  responses from organizer cancellation, and
  [iMIP](https://www.rfc-editor.org/rfc/rfc6047.html) transports scheduling
  messages over email. Provider Calendar API responses require separate Calendar
  authorization, such as Graph's
  [event acceptance API](https://learn.microsoft.com/en-us/graph/api/event-accept?view=graph-rest-1.0).
  Current mailbox grants contain no Calendar scopes.
- Microsoft Graph supports native delegated access to work/school shared mail
  with additional shared-mail scopes and existing Exchange mailbox permissions.
  Permission to read a mailbox does not grant Send As or Send on behalf. Personal
  Outlook.com does not support these shared scopes. See Microsoft's
  [shared-mail access](https://learn.microsoft.com/en-us/graph/outlook-share-messages-folders)
  and [delegated sending](https://learn.microsoft.com/en-us/graph/outlook-send-mail-from-other-user)
  guidance. Shared-mail push subscriptions have separate limitations; this path
  does not establish identical freshness to an own mailbox.
- Google's [delegate management API](https://developers.google.com/workspace/gmail/api/guides/delegate_settings)
  requires service-account/domain-wide authority. It does not establish that an
  ordinary user's OAuth token can read or send from a mailbox delegated to them
  in Gmail's interface. No supported path for that use of the existing native
  public-client grant was established by this research, and the
  [Gmail delegation spike](../gmail-delegation-spike.md) found none in Google's
  current documentation. Do not treat separately authorizing another person's
  mailbox as verified delegation support.
- IMAP [namespaces](https://www.rfc-editor.org/rfc/rfc2342.html) and
  [ACL rights](https://www.rfc-editor.org/rfc/rfc4314.html) depend on server
  capabilities and granted rights. Discovering a shared folder does not establish
  write, expunge or SMTP sending authority.
- Current received attachment files use temporary preview storage rather than
  persistent Keep Offline retention. Routine preview cleanup and an explicit
  request to remove indexed content are different events. The lifetime of
  extracted text after temporary-file cleanup is confirmed under attachment search;
  see [received attachment storage](../gmail-inbox.md#received-attachments).
  Derived text, snippets and indexes must inherit account/Profile isolation,
  Profile Lock and removal boundaries. The separately scoped metadata-only
  Spotlight contract does not authorize attachment indexing.
- Apple [Vision](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
  provides on-device image OCR, and [PDFKit](https://developer.apple.com/documentation/pdfkit/pdfpage)
  exposes PDF text and page rendering. Scanned-PDF OCR can combine those
  capabilities, subject to bounded processing and qualified recognition
  languages. Quick Look preview of an Office file does not prove a supported
  text-extraction path. Initial formats and language quality remain to be
  qualified.

### Owner decisions

Round 1 settled the launch boundary, first new capability, rejection of the
proposed real-use trial, and the need for specific local pending-work explanations.
The owner then expanded exploration to every gap and candidate above.

Round 2 settled Q5–Q16. Round 3 settled Q17–Q29, including defaults, unattended
warning handling, status disclosure, indexing consent and retention, invitation
updates, recoverable automation deletion, device-local controls and the first
delegation providers. The Confirmed behavior section owns those requirements.
The independent simplicity and documentation reviews found no remaining material
owner questions. The owner confirmed the complete shared understanding at Q30
and requested tracer-bullet delivery tickets. The owner then approved all 46
slices, their granularity and blocking edges. Existing parent issues remain
unchanged. Implementation details that preserve these contracts do not require
another product interview.
Record settled vocabulary in its owning [topic glossary](../../GLOSSARY.md),
behavior in feature documentation, and only qualifying architectural trade-offs
in reviewer-owned decision records. The completed documentation review covers the accepted behavior and glossary.
Editorial status updates and the delivery index preserve that reviewed scope.

## Delivery tickets

The owner approved all 46 tickets and their 56 native blocking dependencies on
2026-10-25. Runtime implementation follows the accepted power-user launch
[#844](https://github.com/unwired-dev/product/issues/844), directly or through
the approved dependency chain. The two evidence spikes can start independently.
Publication does not establish implementation or release qualification.

The reviewed Calendar policy in [#1315](https://github.com/unwired-dev/product/issues/1315) deliberately follows
[#1281](https://github.com/unwired-dev/product/issues/1281) and replaces its
automatic Unwired Calendar writes with reviewed changes in this follow-up.
Existing parent issues and the first MCP milestone remain unchanged.

The approved first Office-extraction formats are DOCX, XLSX and PPTX.
The approved first archive formats are EML and MBOX.

| Workstream                    | Delivery issues                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sending and status            | [#1295](https://github.com/unwired-dev/product/issues/1295), [#1296](https://github.com/unwired-dev/product/issues/1296), [#1297](https://github.com/unwired-dev/product/issues/1297), [#1298](https://github.com/unwired-dev/product/issues/1298), [#1299](https://github.com/unwired-dev/product/issues/1299), [#1300](https://github.com/unwired-dev/product/issues/1300), [#1301](https://github.com/unwired-dev/product/issues/1301)                                                                                                                                                                                        |
| Focus and sender evidence     | [#1302](https://github.com/unwired-dev/product/issues/1302), [#1303](https://github.com/unwired-dev/product/issues/1303), [#1304](https://github.com/unwired-dev/product/issues/1304), [#1305](https://github.com/unwired-dev/product/issues/1305), [#1306](https://github.com/unwired-dev/product/issues/1306), [#1307](https://github.com/unwired-dev/product/issues/1307)                                                                                                                                                                                                                                                     |
| Attachments                   | [#1308](https://github.com/unwired-dev/product/issues/1308), [#1309](https://github.com/unwired-dev/product/issues/1309), [#1310](https://github.com/unwired-dev/product/issues/1310), [#1311](https://github.com/unwired-dev/product/issues/1311), [#1312](https://github.com/unwired-dev/product/issues/1312), [#1313](https://github.com/unwired-dev/product/issues/1313), [#1314](https://github.com/unwired-dev/product/issues/1314)                                                                                                                                                                                        |
| Invitations                   | [#1315](https://github.com/unwired-dev/product/issues/1315)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Automation                    | [#1316](https://github.com/unwired-dev/product/issues/1316), [#1317](https://github.com/unwired-dev/product/issues/1317), [#1318](https://github.com/unwired-dev/product/issues/1318), [#1319](https://github.com/unwired-dev/product/issues/1319), [#1320](https://github.com/unwired-dev/product/issues/1320), [#1321](https://github.com/unwired-dev/product/issues/1321), [#1322](https://github.com/unwired-dev/product/issues/1322), [#1323](https://github.com/unwired-dev/product/issues/1323), [#1324](https://github.com/unwired-dev/product/issues/1324), [#1325](https://github.com/unwired-dev/product/issues/1325) |
| Provider rules and language   | [#1326](https://github.com/unwired-dev/product/issues/1326), [#1327](https://github.com/unwired-dev/product/issues/1327), [#1328](https://github.com/unwired-dev/product/issues/1328), [#1329](https://github.com/unwired-dev/product/issues/1329), [#1330](https://github.com/unwired-dev/product/issues/1330)                                                                                                                                                                                                                                                                                                                  |
| Delegation                    | [#1331](https://github.com/unwired-dev/product/issues/1331), [#1332](https://github.com/unwired-dev/product/issues/1332), [#1333](https://github.com/unwired-dev/product/issues/1333), [#1334](https://github.com/unwired-dev/product/issues/1334), [#1335](https://github.com/unwired-dev/product/issues/1335)                                                                                                                                                                                                                                                                                                                  |
| Portability and system search | [#1336](https://github.com/unwired-dev/product/issues/1336), [#1337](https://github.com/unwired-dev/product/issues/1337), [#1338](https://github.com/unwired-dev/product/issues/1338), [#1339](https://github.com/unwired-dev/product/issues/1339), [#1340](https://github.com/unwired-dev/product/issues/1340)                                                                                                                                                                                                                                                                                                                  |

The independent evidence tasks are Gmail delegation [#1335](https://github.com/unwired-dev/product/issues/1335) and
Microsoft mailbox import fidelity [#1340](https://github.com/unwired-dev/product/issues/1340). Each must return a supported
path with reproducible evidence or a concrete blocker, without changing runtime
scope or the credential model. The
[Microsoft import fidelity spike](../microsoft-import-fidelity-spike.md) found
that Graph creates only Drafts from MIME; IMAP `APPEND` awaits live proof.
