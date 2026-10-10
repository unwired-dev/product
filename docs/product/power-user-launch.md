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
