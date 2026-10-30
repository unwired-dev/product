# Gmail delegation spike

[#1335](https://github.com/unwired-dev/product/issues/1335) asks whether the
hosts' native public-client Gmail grant can reach a mailbox that its owner
delegated to the signed-in person. It changes no runtime scope or credential.
Official sources were read on 2026-10-30.

## Result

No supported path was identified for the hosts' existing grant
([what the hosts request](google-registration.md#what-the-hosts-request)), so its
supported delegated-mailbox operations are none. Gmail delegation stays
unavailable, and delegated-mail delivery begins with Microsoft 365 and qualified
IMAP servers
([mail capability expansion](product/mail-capability-expansion.md#languages-and-individual-delegation)).

This is an inference from the reviewed documentation, pending the blocked
[live proof](#live-proof). Google documents delegated-mailbox use only in Gmail's
own clients, and the reviewed Gmail API and IMAP references describe no way for a
user's token to address a mailbox delegated to that user. Delegate management
and IMAP access with `gmail.imap_admin` are separate mechanisms; both require a
Google Workspace service account with domain-wide authority, which the
credential model excludes.

## Managing delegates

The
[`users.settings.delegates`](https://developers.google.com/workspace/gmail/api/guides/delegate_settings)
methods create, list, get and delete delegates. Each method states: "This method
is only available to service account clients that have been delegated
domain-wide authority." Delegator and delegate must belong to the same Workspace
organization. Managing delegates therefore stays in Gmail's own settings.

## Using a delegated mailbox

- **Gmail's own clients.** A delegate opens the owner's mailbox from the account
  switcher entry marked "Delegated" in Gmail on the web or the Gmail app for
  iPhone and iPad
  or Android ([Gmail Help](https://support.google.com/mail/answer/138350)).
  The reviewed sources identify no third-party client path.
- **Gmail API.** The `userId` path parameter is "The user's email address. The
  special value `me` can be used to indicate the authenticated user"
  ([`users.messages.list`](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list)).
  The reviewed references describe no scope or parameter for a mailbox
  delegated to that user.
- **IMAP.** [XOAUTH2](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol)
  needs `https://mail.google.com/`, which the hosts do not request. Its
  alternative scope, `gmail.imap_admin`, "can only be used for Google Workspace
  domain-wide delegation."

Separately authorizing another owner's account, by having the owner sign in on
the device, creates an ordinary Gmail connection for that owner. It is not
delegation.

## Delegation prerequisites

These apply in Gmail itself and would constrain any future path:

- In Workspace, delegator and delegate must be in the same organization, and an
  administrator must enable **Let users delegate access to their mailbox to other
  users in the domain**
  ([Workspace Admin Help](https://knowledge.workspace.google.com/admin/gmail/let-users-delegate-access-to-a-gmail-account)).
- The delegate accepts an emailed invitation within a week. Access can take up to
  24 hours to start ([Gmail Help](https://support.google.com/mail/answer/138350)).

## Live proof

Not run. No attested Gmail test account is available
([#1528](https://github.com/unwired-dev/product/issues/1528)), and no protected
workflow runs a delegation probe. The proof needs two
[Provider Test Accounts](gmail-provider-test-tenant.md) with a ready attestation,
an accepted delegation between them, and a protected native probe added to the
operator-run workflow. Gmail tokens stay inside the native device boundary, and
the probe requests no new scope. The authorized operator then:

1. In Gmail on the web, has owner account B add delegate A. A accepts the
   invitation and, after up to 24 hours, sees B marked "Delegated" in the
   account switcher.
2. Signs A in through the hosts' existing Gmail consent, and the probe verifies
   inside the native boundary that the token belongs to A and that its granted
   scopes are exactly the hosts' current set.
3. With A's token, calls `GET https://gmail.googleapis.com/gmail/v1/users/me/profile`
   as a control whose address must match A, then
   `GET https://gmail.googleapis.com/gmail/v1/users/<B>/profile`.

Record only redacted run metadata, status codes and Google's error reason, never
addresses, tokens, response bodies or mailbox content. A failed control, or an
error reason about quota, rate limits or domain policy
([Gmail API errors](https://developers.google.com/workspace/gmail/api/guides/handle-errors)),
makes the run inconclusive. A permission denial on B with a passing control
shows only that this request fails for this setup; it supports this result
without proving every operation unsupported. A `200` shows only profile access
to B and reopens the evaluation as a separately scoped slice.
