# Assistant inside Gmail and Outlook evaluation

[#1665](https://github.com/unwired-dev/product/issues/1665) asks whether a
standalone assistant could work inside a person's existing Gmail or Outlook
mailbox without the native mail UI. The comparison is Superhuman's Email
Assistant (scopes SH-299, SH-301, SH-302, SH-304, SH-305, SH-306 and SH-308).
It would label and archive mail, send a daily archive digest, write response,
follow-up and scheduling Drafts, and keep independent settings for each account.
This evaluation changes no runtime, registration, scope or credential, and it
authorizes no automatic action. Sources were read on 2026-11-11. Superhuman's
two help articles returned HTTP 403, so its background behavior comes from the
[product page](https://superhuman.com/agents/email-assistant). The assistant Cc,
digest email and dashboard come from the issue's scope titles.

## Decision

**No-go** for a standalone assistant that works in the provider mailbox while
Unwired is not running. Superhuman's assistant "works in the background in every
Gmail and Outlook account" and lets people "open your inbox and see email already
handled". Doing that needs one of two things, and the product excludes both:

- **A hosted service** that holds provider tokens and reads mail. ADR 0002
  forbids it, and the issue rules out a hosted mailbox reader.
- **Dependable background execution on the device.** Apple does not provide it.
  [ADR 0013](adr/0013-best-effort-device-side-mail-freshness.md) already accepts
  delayed background updates instead of "operating a credential-holding backend
  mail service". Unwired would also need background inference that runs
  automatically. Background PCC is deferred, and on-device background work may
  not write replies.

The owner can reopen this evaluation through a new issue that accepts specific
trade-offs from [Boundaries](#boundaries). Parts of the scope fit the product
when they run inside Unwired on a Trusted Device. Those parts are listed in
[Follow-up proposals](#follow-up-proposals) for owner approval.

## Prototype

Not run. The bounded provider-visible Draft and organization workflow needs
disposable provider accounts, and none is available to this host:

- **Gmail.** The dedicated consumer test accounts are still waiting for a person
  ([#1528](https://github.com/unwired-dev/product/issues/1528)).
- **Microsoft.** [#1104](https://github.com/unwired-dev/product/issues/1104)
  closed without a completion note, and this host still has no Outlook.com or
  Microsoft 365 test mailbox. The closure has been
  [queried on the issue](https://github.com/unwired-dev/product/issues/1104#issuecomment-6796236194).
- **Production mail is excluded** by
  [ADR 0032](adr/0032-use-only-synthetic-mail-in-test-environments.md).

A prototype run inside Unwired would show only what the hosts will do while the
app runs, once provider Drafts and Mail Rules land. It would not show the
background behavior the evaluation is about, so these blockers do not change the
decision.

## Boundaries

### Where the assistant runs

- **No hosted reader.** [ADR 0002](adr/0002-device-held-mail-provider-tokens-with-push-relay.md)
  keeps provider tokens on devices. The backend may not fetch mail, read bodies
  or categories, or classify mail. Its only role with mail data is to relay
  Minimal Push Metadata to APNs.
- **iPhone and iPad background time is not guaranteed.** Background tasks run
  when "the system decides the best time to launch your background task", and
  for a refresh request "the system doesn't guarantee launching the task at the
  specified date, but only that it won't begin sooner"
  ([choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app),
  [`earliestBeginDate`](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)).
  Neither supports a promise like "already handled when you open your inbox".
- **A Mac keeps working only while Unwired runs.** A background helper that
  keeps running after Quit is still an open owner go/no-go
  ([#660](https://github.com/unwired-dev/product/issues/660)). Device-run
  Mail Rules accept the same limit. They "do not promise execution while all
  trusted clients are unavailable"
  ([power-user launch](product/power-user-launch.md)).

### Provider authorization

The current scopes already cover the provider-visible actions of a device-run
assistant.

- **Gmail.** `users.drafts.create` accepts `gmail.modify`, the hosts' only mail
  scope ([Gmail API](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.drafts/create),
  [what the hosts request](google-registration.md#what-the-hosts-request)). The
  same grant covers labels, archive and sending.
- **Microsoft.** `Mail.ReadWrite` and `Mail.Send` cover Drafts, moves and the
  `categories` on a message ([Microsoft mail](microsoft-mail.md),
  [update message](https://learn.microsoft.com/en-us/graph/api/message-update?view=graph-rest-1.0)). Outlook's
  master category list needs a further permission. Reading the list requires
  `MailboxSettings.Read` and creating a category requires
  `MailboxSettings.ReadWrite`
  ([list](https://learn.microsoft.com/en-us/graph/api/outlookuser-list-mastercategories?view=graph-rest-1.0),
  [create](https://learn.microsoft.com/en-us/graph/api/outlookuser-post-mastercategories?view=graph-rest-1.0)).
  Creating assistant categories in Outlook would therefore add a scope and a
  consent change.

### Existing labels and categories (SH-301)

A Message Category is Unwired product state, and it never changes provider state.
Only a Provider Mail Action does ([organization](product/organization.md)).
Existing Gmail labels and Outlook categories therefore stay as they are today.
A provider-visible assistant category would be new provider state, and it would
need its own authorization and design approval.

### Model and automatic actions

- **PCC.** Apps reach Private Cloud Compute only through native Foundation
  Models sessions and need a managed entitlement
  ([`PrivateCloudComputeLanguageModel`](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel)).
  [ADR 0075](adr/0075-prefer-private-cloud-compute-for-separately-authorized-mail-assistance.md)
  says "Background PCC is a deferred evaluation, not authorization under this
  decision", and the owner kept that evaluation deferred
  ([#1458](https://github.com/unwired-dev/product/issues/1458)). Automatic
  analysis, even while Unwired runs, is the work #1458 defers, so this
  evaluation proposes no automatic PCC use. Any later PCC use keeps ADR 0075's
  rules: a separate opt-in for each device and Mail Profile, disclosure of the
  daily quota, offline unavailability and refusals, no retry on another model
  after a refusal, and a local fallback only when it completes the same
  operation and says so.
- **On-device background work.** Background Message Summaries and, after
  launch, System Categorization of new mail
  ([#649](https://github.com/unwired-dev/product/issues/649)) and Mail
  Commitment Suggestions
  ([ADR 0072](adr/0072-allow-reviewed-post-launch-mail-commitments.md)) are the
  only automatic assistance. None of them writes a reply. [ADR 0068](adr/0068-allow-device-local-background-message-summaries.md)
  says its exception "does not authorize background Thread analysis, automatic
  replies or edits, cloud inference, or synchronized generated text". Automatic
  response and follow-up Drafts (SH-305) need a new decision.
- **External effects.** Under [ADR 0073](adr/0073-separate-external-agent-access-from-on-device-assistance.md),
  "Sending and mailbox organization remain actions the user performs in
  Unwired". [Follow-Up Nudges](adr/0051-keep-follow-up-nudges-private-and-device-delivered.md)
  never draft or send a message. Deterministic rules the person writes, such as
  Mail Rules and [Blocked Senders](adr/0051-enforce-profile-blocked-senders-on-trusted-devices.md),
  are the only automatic moves. No Mail Assistance, PCC or Agent Connection
  opt-in grants automatic archive, provider Drafts or mail sent on the person's
  behalf. Each would need its own grant, separate from the grant that lets a
  model analyze mail.
- **Untrusted input and acceptance.** Generated text comes from received mail.
  It must keep its source Thread and revision, stay unsaved until the person
  accepts it, and be dropped when its source changes, like current
  [Draft assistance](draft-assistance.md). A generated provider Draft would
  reach the provider before anyone accepted it, and the person could send it
  from Gmail or Outlook without Unwired's review. ADR 0075 keeps generated
  changes "behind explicit undoable acceptance", so an assistant may not save
  provider Drafts on its own.

### Scope items that stay out

- **Assistant Cc for scheduling (SH-306).** The assistant would need its own
  address that receives mail and answers it. That is a hosted mailbox reader,
  which the issue excludes. It would also give the assistant an identity of its
  own. Unwired has none: an accepted suggestion is the person's Draft.
- **Scheduling Drafts (SH-306).** Proposing times needs calendar availability.
  Unwired reads calendars only to add, update and remove invitations the person chose
  ([ADR 0045](adr/0045-keep-contact-and-event-content-out-of-product-sync.md)).
  Reading free and busy time for replies would be a new data use, and it is not
  proposed here.
- **Daily archive digest email (SH-304).** A generated email about archived
  mail would be an automatic send. The same summary fits inside Unwired without
  sending anything (proposal 3).
- **Independent dashboard settings (SH-308).** Superhuman's dashboard lives on
  its service. In Unwired, Mail Rules belong to a Mail Profile, and synchronized
  settings travel through Private Sync. Proposal 2 keeps that Profile scope and
  can match one Mailbox Connection. Proposal 4 grants analysis per Mailbox
  Connection and device.

## Follow-up proposals

None of these has been filed. Each needs owner approval first, and none adds a
launch gate.

1. **Prove provider-visible results with test accounts.** Once #1528 and #1104
   provide accounts, run the bounded workflow inside Unwired once its parts
   land: save a reply that used a reply suggestion as a provider Draft
   ([Gmail #1269](https://github.com/unwired-dev/product/issues/1269),
   [Microsoft #1270](https://github.com/unwired-dev/product/issues/1270)),
   archive with a Mail Rule
   ([#852](https://github.com/unwired-dev/product/issues/852)), then confirm in
   Gmail and Outlook that the Draft appears and existing labels and categories
   are unchanged. This checks planned product behavior against the assistant
   scope. It adds no automatic action.
2. **Archive by Category with a Mail Rule (SH-302).** Launch Mail Rules match
   sender, recipient, subject and mailing-list conditions. Add a System Category
   or Custom Category condition so a rule can archive a Category. A Category is
   model output, so this condition makes the rule depend on categorization,
   which follows launch ([#649](https://github.com/unwired-dev/product/issues/649),
   [#650](https://github.com/unwired-dev/product/issues/650)). It needs its own
   grant beyond Mail Assistance Enablement. New-Mail-Only Categorization leaves
   older mail Uncategorized, so the preview covers only categorized mail. Like
   other Mail Rules, it runs only while a Trusted Device runs Unwired and shows
   its pending work. A Mail Rule is defined as working
   [without model inference](domain/organization.md), so this needs a
   terminology decision first: widen the term, or give archiving by Category
   its own name and setting.
3. **Show what was archived in Catch Up (SH-304).** Add a daily, local list of
   what Mail Rules archived to [Catch Up](catch-up.md), with Undo, instead of an
   email digest.
4. **Decide on device-run reply suggestions (SH-305).** This needs a new ADR
   that amends ADR 0068 and the explicit-request rules of
   [ADR 0052](adr/0052-keep-mail-assistance-on-device-and-input-bound.md). It
   would add a default-off analysis grant for each Mailbox Connection and device.
   On a Trusted Device running Unwired, the device model would prepare reply and
   follow-up suggestions for Threads that need a response. Each stays a local
   suggestion inside Unwired until the person accepts it into their own Draft,
   and it is dropped when its Thread changes. Nothing reaches the provider, and
   nothing is sent automatically. Automatic PCC use stays with #1458.
