# Power-user mail launch

Confirmed product requirements from the feature-gap interview. This is the launch
target for the maintained iPhone, iPad and Mac clients, not a statement that the
features are implemented or qualified. It replaces the earlier Gmail-only launch
scope with Gmail, IMAP/SMTP and Microsoft mail. A Gmail beta remains a useful
intermediate milestone; it is not the completed launch.

[Launch tracking issue #844](https://github.com/unwired-dev/product/issues/844)
owns implementation completion. [Documentation issue #843](https://github.com/unwired-dev/product/issues/843)
owns this specification and roadmap reconciliation.

## Audience and priority

- Serve an individual managing multiple personal and work Mailbox Connections.
- Include power-user workflows in the first release.
- Prioritize reliable everyday mail over Catch Up and other new AI experiences.
- Keep team assignment, shared-inbox collaboration and CRM workflows outside this
  launch.
- Include optional Mail Profiles, such as Work and Personal, with separate
  mailbox collections, unified Inbox, search, sending defaults and notification
  policy. Start with one default Profile without requiring additional setup.

## Providers

- Gmail is required at launch.
- IMAP and SMTP are both required for a complete Standards-Based Mailbox
  Connection. Certify iCloud Mail and Fastmail and support reviewed manual
  configuration for other compatible servers. Explain unsupported capabilities
  and connection failures without claiming universal server compatibility.
- Support personal Outlook.com and work/school Microsoft 365 mailboxes.
- Defer shared and delegated Microsoft mailboxes.
- Keep Google and Apple Product Sign-In. Microsoft mailbox authorization is
  separate; Microsoft Product Sign-In and linking remain follow-up work in
  [#633](https://github.com/unwired-dev/product/issues/633).

The current IMAP/SMTP work is tracked in
[#629](https://github.com/unwired-dev/product/issues/629),
[#630](https://github.com/unwired-dev/product/issues/630),
[#631](https://github.com/unwired-dev/product/issues/631) and
[#632](https://github.com/unwired-dev/product/issues/632).
Microsoft work is tracked in
[#634](https://github.com/unwired-dev/product/issues/634),
[#635](https://github.com/unwired-dev/product/issues/635),
[#636](https://github.com/unwired-dev/product/issues/636) and
[#637](https://github.com/unwired-dev/product/issues/637).
These provider capabilities are launch requirements. Provider implementation and
qualification may progress before distribution of the intermediate Gmail beta.

## First mailbox after Product Sign-In

After Google or Apple Product Sign-In and any required device enrollment,
offer the Mail Provider choices independently: Gmail, iCloud Mail, Fastmail,
manual IMAP/SMTP, and Microsoft mail. A person can choose a non-Gmail first
Mailbox Connection without granting Gmail access or linking another Product
Sign-In. Google sign-in may suggest its Google mailbox, but must also offer the
other providers; an Apple contact or relay address is not a mailbox selection.

Choosing another provider skips Gmail authorization. Cancelling, declining or
failing the selected provider's setup keeps the Product Account and returns to
resumable mailbox setup, with retry and provider selection available. It never
silently starts Gmail authorization or creates a connected Inbox. Without any
verified Mailbox Connection, remaining in setup does not expose a mail Inbox.
Once the selected provider's connection is verified and other setup requirements
are complete, open that mailbox's Inbox. Additional connections follow the same
provider choice and preserve existing connections on cancellation or failure.
Product Sign-In, trusted-device admission and mailbox verification remain
separate requirements.

The [Google](../google-registration.md) and [Apple](../apple-registration.md)
registration guides distinguish their current Gmail path and evidence from this
required launch journey. First-connection implementation belongs to the existing
provider slices [#629](https://github.com/unwired-dev/product/issues/629) and
[#634](https://github.com/unwired-dev/product/issues/634); qualification
[#855](https://github.com/unwired-dev/product/issues/855) must cover both Product
Sign-In choices, each launch Mail Provider as the first connection, cancellation,
retry, provider switching and relaunch. Non-Gmail journeys must complete those
checks without a Gmail grant.

## Everyday reliability

- Make mailbox navigation and complete conversation history available, including
  Sent, Archive/All Mail, Spam, Trash and provider folders or labels.
- Recover interrupted sending without duplicate delivery, distinguish confirmed
  failures from uncertain outcomes, and provide a safe recovery path.
- Protect unsaved Draft edits when leaving the composer, closing a window or
  quitting the app.
- Keep mail fresh within platform execution limits and provide dependable,
  private new-mail notifications.
- Include per-connection notification switches, generic notification content by
  default, optional sender/subject previews, quiet hours and sender/rule-based
  filtering. These controls must work without AI categorization.

Existing work includes delivery recovery
[#616](https://github.com/unwired-dev/product/issues/616), Outbox execution
[#618](https://github.com/unwired-dev/product/issues/618), native composer exits
[#778](https://github.com/unwired-dev/product/issues/778), lifecycle freshness
[#617](https://github.com/unwired-dev/product/issues/617), push registration
[#781](https://github.com/unwired-dev/product/issues/781), notifications
[#619](https://github.com/unwired-dev/product/issues/619), and the mobile Thread
reader [#809](https://github.com/unwired-dev/product/issues/809).
These tickets cover parts of the launch requirement, not the complete
multi-provider implementation or qualification.

## Confirmed scope additions from 2026-10-24

The continued feature-gap interview confirmed these additional launch
requirements. They describe the target behavior, not current implementation or
passing qualification.

- Support sending Microsoft messages larger than the current 3 MB total-message
  limit, including attachments, within the selected mailbox's supported limits.
  Existing [#917](https://github.com/unwired-dev/product/issues/917) is required
  for launch.
- Let people explicitly Accept, Tentatively Accept, or Decline meeting
  invitations and send the response to the organizer. Adding an event to a
  calendar alone does not satisfy invitation-response support. Adding the event
  to a selected calendar is a separate optional choice requiring explicit
  calendar permission; responding must not require adding it to a calendar.
  For events the person chose to add, automatically apply valid organizer
  updates and cancellations without requiring review each time. Match the
  original invitation and organizer, avoid duplicate events, and do not apply
  inferred changes from ordinary message prose. Unwired's optional Add action
  does not override the Mail Provider's own invitation-processing settings.
- Use provider-hosted Drafts for Gmail, Microsoft mail, and IMAP/SMTP connections.
  People must be able to continue those Drafts in Unwired and compatible mail
  clients, including Drafts started outside Unwired. This supersedes the earlier
  launch boundary that kept provider Drafts read-only. The provider's Draft is
  the canonical synchronized copy. Keep an encrypted device-local copy for
  offline editing and pending uploads, and replace Private Sync as the transport
  for Draft content.
- Preserve both versions when concurrent edits from Unwired and another mail
  client are detected, and ask the person to resolve them rather than silently
  overwriting either known version.
- If a Draft was sent or deleted elsewhere while Unwired held offline edits,
  preserve those edits as a separate recovered Draft. Do not restore the
  original provider Draft or send anything automatically.
- Once a message is durably admitted to Unwired's Outbox, retire its provider
  Draft. Undo restores an editable Draft locally and synchronizes it to the
  provider when access is available. Recovery must preserve content and avoid
  duplicate submissions by Unwired when either transition is interrupted or its
  provider outcome is uncertain.
- Automatically migrate existing Unwired Drafts to their owning providers.
  Retain the encrypted local content until each upload is confirmed, and wait
  safely while offline or provider authorization is unavailable.
- Require fully lossless editing of provider-hosted Drafts at launch, including
  Drafts created in other clients. Preserve all content and visible formatting,
  including tables, fonts, colors, alignment, links, Inline Images, and
  Attachments. The underlying HTML or MIME encoding may change; byte-identical
  source preservation is not required. Opening or editing a Draft must not
  silently strip content, and a conversion that discards unsupported formatting
  is not the accepted fallback. This supersedes earlier formatting restrictions
  wherever they would prevent lossless editing, while retaining the existing
  message safety and remote-content boundaries. Lossless editing does not
  authorize executing unsafe message content or fetching remote resources.

Conflict recovery preserves versions known to Unwired; it cannot recover edits
another client never exposes. Outbox safety governs Unwired's own submissions
and does not promise a global send lock across other mail clients.

The provider receives Draft content before sending. Provider credentials and
readable Draft content must still stay outside the product backend. The current
[Draft guide](../drafts.md) continues to describe the implemented product-owned
Drafts and their Private Sync behavior until the replacement is implemented.
The [published delivery slices](#provider-draft-and-invitation-delivery-slices)
cover these additions; GitHub owns completion and native blocking relationships.
Their publication does not establish implementation or qualification.
Qualification must cover cross-client continuation and formatting,
concurrent and offline edits, remote sending and deletion, migration, interrupted
Draft/Outbox transitions, larger Microsoft sends, and invitation responses with
and without optional calendar addition and later organizer changes.

## Power-user workflows

- Keyboard navigation and shortcuts, bulk actions and undo.
- Advanced search, saved searches and provider label or folder management.
- Recipient autocomplete, verified Sending Identities, signatures and Mail
  Templates.
- Thread Snooze and reply-aware Follow-Up Nudges.
- Explicit deterministic Mail Rules, initially matching sender, recipient,
  subject and mailing-list conditions and offering organization actions such as
  moving mail, applying a label or marking it read. Preview changes before
  applying rules to existing mail.
- Execute Mail Rules on trusted devices, showing pending work and catching up
  when a client resumes. Launch rules do not promise execution while all trusted
  clients are unavailable; always-on provider-side rules are separate work.

Scheduled Send follows dependable delivery recovery. It is not included in the
accepted launch toolkit merely because Thread Snooze and Follow-Up Nudges are.
AI categorization follows the everyday reliability work.

## Search and offline availability

- Replace the current 200-Inbox-message metadata cutoff with progressive,
  resumable Historical Metadata Backfill covering the provider-visible mailbox
  history. Do not block initial use on completion of that backfill.
- Make the whole synchronized metadata history searchable offline and make
  incomplete synchronization visible.
- Search downloaded message bodies offline, distinguish partial body coverage
  from complete metadata coverage, and offer an explicit online search for the
  remainder. No matches in downloaded content must not imply no matching mail
  exists at the provider.
- Use a configurable cache for ordinary downloaded message bodies.
- Provide Keep Offline for selected conversations or folders, with optional
  attachments. Retain explicitly downloaded content independently of ordinary
  body-cache eviction until the user releases it, subject to the product's
  existing deletion and authorization boundaries.
- Show download progress, failures, storage usage and which content is actually
  available offline. Selecting Keep Offline is a request; an incomplete download
  is not yet available offline.
- Keep Pin separate from Keep Offline; pinning alone does not promise retained
  bodies or attachments.

The current implementation limits and online-search behavior remain documented
in [Gmail Inbox](../gmail-inbox.md#searching-saved-mail). This specification does
not change those implementation claims.

## Native workflows

- Default-mail-app integration and `mailto:` handling.
- Sharing content and files into an editable Draft.
- Desktop attachment drag-and-drop.
- Printing messages and exporting an individual message as `.eml`.

Spotlight indexing and bulk mailbox import/export can follow launch. Android and
Windows remain later platform work.

## Qualification

The complete receive, find, read, organize, compose, reply, send, verify and
recover workflow needs evidence on iPhone, iPad and Mac, including offline use,
relaunch and multiple Mailbox Connections. Existing real-Gmail
[#624](https://github.com/unwired-dev/product/issues/624), native-host
[#623](https://github.com/unwired-dev/product/issues/623), and accessibility and
performance [#626](https://github.com/unwired-dev/product/issues/626) work does not
substitute for equivalent evidence for IMAP/SMTP and Microsoft mail.

Implementation, deterministic tests and real provider/native qualification are
separate statuses. Prototype features and closed prototype tickets do not prove
replacement support.

## Delivery order

1. Complete delivery recovery, Draft protection, mailbox navigation, conversation
   history and provider foundations.
2. Complete historical metadata, search and offline retention; introduce the
   Default Profile and the existing Profile migration slices without losing
   connections, Drafts or queued work.
3. Complete the accepted power-user, notification and native workflows across
   all launch providers and Apple hosts.
4. Qualify the full workflows with real providers and packaged native clients
   before public release. Keep unavailable evidence visible as release blockers.

Catch Up and new AI experiences follow everyday reliability. Implementation
tickets own technical details and measurable verification for their slices;
this specification does not prescribe storage quotas or an implementation design.

## Implementation slices

Reuse the existing provider, Profile and reliability tickets. The following
replacement tickets cover the gaps identified in the code and issue audit:

| Area                                                     | Issue                                                     |
| -------------------------------------------------------- | --------------------------------------------------------- |
| Mailbox navigation and historical metadata               | [#845](https://github.com/unwired-dev/product/issues/845) |
| Complete conversations across hosts/providers            | [#846](https://github.com/unwired-dev/product/issues/846) |
| Offline/body search, coverage and saved searches         | [#847](https://github.com/unwired-dev/product/issues/847) |
| Keep Offline and storage controls                        | [#848](https://github.com/unwired-dev/product/issues/848) |
| Keyboard navigation and recoverable bulk actions         | [#849](https://github.com/unwired-dev/product/issues/849) |
| Recipients, Sending Identities, signatures and templates | [#850](https://github.com/unwired-dev/product/issues/850) |
| Thread Snooze and Follow-Up Nudges                       | [#851](https://github.com/unwired-dev/product/issues/851) |
| Device-run deterministic Mail Rules                      | [#852](https://github.com/unwired-dev/product/issues/852) |
| Quiet hours and explicit notification filtering          | [#853](https://github.com/unwired-dev/product/issues/853) |
| Native mail, sharing, printing and export workflows      | [#854](https://github.com/unwired-dev/product/issues/854) |
| Expanded provider/native launch qualification            | [#855](https://github.com/unwired-dev/product/issues/855) |

Optional Profiles use the existing migration sequence
[#644](https://github.com/unwired-dev/product/issues/644),
[#645](https://github.com/unwired-dev/product/issues/645),
[#646](https://github.com/unwired-dev/product/issues/646) and
[#647](https://github.com/unwired-dev/product/issues/647). Public distribution
[#669](https://github.com/unwired-dev/product/issues/669) must wait for the
expanded launch qualification; it remains separate from the intermediate
TestFlight milestone [#628](https://github.com/unwired-dev/product/issues/628).

## Provider Draft and invitation delivery slices

The owner approved this breakdown on 2026-10-24. Each implementation slice owns
its complete affected journey, tests, native evidence and documentation.
Dependencies are recorded as native GitHub blocking relationships. Existing
launch, calendar and qualification parent issue bodies remain unchanged.

| Delivery slice                                                  | Issue                                                                                                                               |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Preserve rich Draft formatting while editing                    | [#1267](https://github.com/unwired-dev/product/issues/1267)                                                                         |
| Edit tables without flattening Drafts                           | [#1268](https://github.com/unwired-dev/product/issues/1268)                                                                         |
| Create and continue Gmail provider Drafts                       | [#1269](https://github.com/unwired-dev/product/issues/1269)                                                                         |
| Create and continue Microsoft provider Drafts                   | [#1270](https://github.com/unwired-dev/product/issues/1270)                                                                         |
| Create and continue IMAP provider Drafts                        | [#1271](https://github.com/unwired-dev/product/issues/1271)                                                                         |
| Recover offline Gmail Draft edits                               | [#1272](https://github.com/unwired-dev/product/issues/1272)                                                                         |
| Recover offline Microsoft Draft edits                           | [#1273](https://github.com/unwired-dev/product/issues/1273)                                                                         |
| Recover offline IMAP Draft edits                                | [#1274](https://github.com/unwired-dev/product/issues/1274)                                                                         |
| Move provider Drafts through Outbox and Undo safely             | [#1275](https://github.com/unwired-dev/product/issues/1275)                                                                         |
| Migrate existing Drafts and retire their Private Sync transport | [#1276](https://github.com/unwired-dev/product/issues/1276)                                                                         |
| Send larger Microsoft messages, reusing the existing ticket     | [#917](https://github.com/unwired-dev/product/issues/917)                                                                           |
| Respond to Gmail meeting invitations                            | [#1277](https://github.com/unwired-dev/product/issues/1277)                                                                         |
| Respond to Microsoft meeting invitations                        | [#1278](https://github.com/unwired-dev/product/issues/1278)                                                                         |
| Respond to IMAP meeting invitations                             | [#1279](https://github.com/unwired-dev/product/issues/1279)                                                                         |
| Optionally add invitations to a selected calendar               | [#1280](https://github.com/unwired-dev/product/issues/1280), sub-issue of [#657](https://github.com/unwired-dev/product/issues/657) |
| Apply organizer updates to opted-in calendar events             | [#1281](https://github.com/unwired-dev/product/issues/1281)                                                                         |
| Qualify provider Drafts, larger sends and invitation workflows  | [#1282](https://github.com/unwired-dev/product/issues/1282), sub-issue of [#855](https://github.com/unwired-dev/product/issues/855) |

The new tickets carry `ready-for-agent`; only tickets whose blockers are complete
are on the implementation frontier. The reused Microsoft-send ticket is also
marked ready for an agent and required for launch. The calendar sub-slice leaves
its parent's broader prose-candidate follow-up scope intact.
