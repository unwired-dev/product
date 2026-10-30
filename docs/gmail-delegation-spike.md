# Gmail delegation spike

[#1335](https://github.com/unwired-dev/product/issues/1335) asks whether the
hosts' native public-client Gmail grant can reach a mailbox that its owner
delegated to the signed-in person. It changes no runtime scope or credential.
Official sources were read on 2026-10-30.

## Result

No supported path exists. Gmail delegation stays unavailable, and delegated-mail
delivery begins with Microsoft 365 and qualified IMAP servers
([mail capability expansion](product/mail-capability-expansion.md#languages-and-individual-delegation)).

Google documents two API routes to another person's mailbox, and both require a
Google Workspace service account with domain-wide authority. The
[credential model](google-registration.md#what-the-hosts-request) excludes that
authority, so the supported operations for the hosts' grant are none.

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
  ([Gmail Help](https://support.google.com/mail/answer/138350)). Google
  documents no other client for delegated access.
- **Gmail API.** The `userId` path parameter is "The user's email address. The
  special value `me` can be used to indicate the authenticated user"
  ([`users.messages.list`](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list)).
  No scope or parameter addresses a mailbox delegated to that user.
- **IMAP.** [XOAUTH2](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol)
  needs `https://mail.google.com/`, which the hosts do not request. Its only
  route to other users' mailboxes is `gmail.imap_admin`, which "can only be used
  for Google Workspace domain-wide delegation."

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

Not run. No attested Gmail test account is available to agents
([#1528](https://github.com/unwired-dev/product/issues/1528)), and the proof
needs two accounts with an accepted delegation. Once they exist:

1. In Gmail on the web, owner account B adds delegate A. A accepts the invitation
   and, after up to 24 hours, sees B marked "Delegated" in the account switcher.
2. A grants the hosts' existing Gmail consent. Request no new scope.
3. With A's access token, call
   `GET https://gmail.googleapis.com/gmail/v1/users/<B>/profile`. Record the
   status code and error reason only, never mailbox content.

A `403` confirms this result. A `200` contradicts it and reopens the evaluation
as a separately scoped slice.
