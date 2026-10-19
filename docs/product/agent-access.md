# Agent access requirements

Status: requirements confirmed by the user on 2026-10-19 after the complete
interview. This document does not establish implementation, passing qualification,
or approval to start runtime implementation.

[Vocabulary](../domain/agent-access.md) · [Documentation index](../README.md) ·
[Privacy decision](../adr/0073-separate-external-agent-access-from-on-device-assistance.md)

## Purpose and milestone

External assistants such as Codex and Claude can access a user's connected mail
through Unwired. The representative task is: "Find the conversation about my
invoice, explain what happened, and prepare a reply."

Agent access is a separate follow-up milestone after the currently committed
[power-user mail launch](power-user-launch.md), with its own issue and acceptance
criteria. It does not expand that launch's requirements.

[Documentation issue #1081](https://github.com/unwired-dev/product/issues/1081)
tracks this specification. The implementation tickets below remain open after
the documentation is delivered.

## Delivery tickets

The user approved these vertical slices and their native GitHub blocking
relationships. Each implementation slice includes its affected integration,
UI, tests, and documentation; new visual design requires Figma approval before
code changes.

1. [Authorize local MCP Agent Connections and list scoped mail #1082](https://github.com/unwired-dev/product/issues/1082).
   Blocked by [power-user launch #844](https://github.com/unwired-dev/product/issues/844).
2. [Search and read mail through Agent Connections #1083](https://github.com/unwired-dev/product/issues/1083).
   Blocked by #1082.
3. [Create new-message and reply Drafts through agents #1084](https://github.com/unwired-dev/product/issues/1084).
   Blocked by #1083.
4. [Edit agent-created Drafts without losing user changes #1085](https://github.com/unwired-dev/product/issues/1085).
   Blocked by #1084.
5. [Review and clear local Agent Connection activity #1086](https://github.com/unwired-dev/product/issues/1086).
   Blocked by #1082.
6. [Qualify the complete External Agent mail workflow #1087](https://github.com/unwired-dev/product/issues/1087).
   Blocked by #1083, #1085, and #1086.

The runtime work starts only after #844 completes. Sending, deletion, and other
future action contracts are not implementation-ready slices in this milestone.

## Consent and privacy

External Agent access is separate from built-in On-Device Mail Assistance.
Users separately enable Agent Connections, with clear disclosure that retrieved
mail may be processed by the external agent and its model provider. This qualifies
the product's previous on-device-only AI privacy promise. Built-in assistance
retains its existing no-cloud-fallback contract.

Unwired's product backend gains no access to plaintext mail or provider
credentials. Disabling a connection cannot recall information already returned
to the external agent.

## Connections and Settings

Unwired ships a local MCP helper, with setup instructions for Codex and Claude.
Each new Agent Connection requires approval inside Unwired. The user chooses its
name, exactly one Mail Profile, explicitly selected Mailbox Connections, and
permitted actions. Approval discloses external processing before any mail is
returned.

Settings controls each connection independently. Approved reads and Draft edits
run without repeated prompts. Permission increases require approval inside
Unwired; one connection's permissions confer no authority on another connection.
Switching the app's active Profile does not change a connection's granted scope.

A named connection persists between agent sessions on the same Mac. Its
credentials and configuration stay local and require separate setup on another
Mac. Different projects or assistants can use separate connections.

Disabling a connection immediately blocks further access and preserves saved
Drafts. Request execution must respect the current grant, including when a
permission or selected Mailbox Connection has been removed.

## Mac availability and account boundaries

The first version serves agents through Unwired running on the user's Mac. The
helper can launch Unwired when needed and work with all windows closed. Access
requires an enabled connection and an authorized, signed-in app. A sleeping or
unavailable Mac returns an unavailable result.

Agent access inherits the existing account and storage boundaries:

- A Pending Device, account removal in progress, locked storage, or unavailable
  account keys cannot expose mail or Drafts. See [Draft storage](../private-inbox-storage.md#draft-storage).
- [Profile Lock](privacy-and-sync.md#profile-protection-and-search) protects
  content revealed through agent access as well as the app. A grant does not
  bypass device-owner authentication.
- [Sign-out](../account-removal.md) removes this device's
  account data and access. Account deletion and observed device revocation also
  end agent access. Another Product Account cannot inherit the former account's
  connections, credentials, history, or Drafts.
- Saved Drafts remain subject to the existing [account purge rules](../drafts.md#storage-and-isolation).
  Preserving Drafts when an Agent Connection is disabled does not override them.

## Searching and reading

The first version supports searching and reading within the granted Mail Profile
and selected Mailbox Connections. Search can query provider mail and retrieve
message bodies absent from the local cache.

Search returns paginated results with short previews and stable message
references. Reading selected messages or Threads requires separate explicit
requests. Results identify shortened content, missing content, incomplete
searches, and provider failures. A partial search never claims complete coverage.

Agents can read message text and attachment names and basic metadata. Attachment
contents are outside the first version's scope. Reading does not mark mail read
or perform another mailbox change.

When a provider is unavailable, cached mail remains readable and local Drafts
remain usable under the existing account and storage rules. Results identify
cached data and report its freshness and any missing content. Unavailable bodies
are not fabricated or reported as complete.

## Creating and editing Drafts

The first version supports new-message, Reply, and Reply All Drafts. Agents can
set the subject, body, recipients, and a sending mailbox within their granted
scope. Forwarding and attachment changes are outside this version's scope.

These are ordinary editable Unwired Drafts, available for the user to review and
send. An agent can initially edit only Drafts created by its own Agent Connection.

An agent's edit fails with a conflict if the user has edited the Draft since the
agent read it. The user's changes remain intact, and the agent must reread the
current Draft before attempting another edit. Existing cross-device Draft
conflict preservation remains applicable.

Retrying the same operation after a lost response returns its existing result.
It does not create a duplicate Draft or apply an edit twice. A failed save never
reports success.

Sending, deleting, organizing, and other mailbox changes remain actions the user
performs in Unwired in this version. Future versions can expose these actions
through permissions configurable separately for each Agent Connection in
Settings. Sending and deletion each require explicit enablement when introduced.
Their detailed approval and execution contracts belong to those future features.

## Activity history

A local activity history records the agent, action, time, target references, and
outcome for searches, mail reads, and Draft changes. It stays encrypted locally
for 30 days and offers Clear History.

History records basic action details. It excludes search query text, message
bodies, generated reply text, and credentials. It remains subject to account
isolation and account-data removal.

## Acceptance criteria

The implementation must demonstrate these observable behaviors:

1. A configured Codex or Claude client completes the invoice search, selected
   Thread read, and reply-Draft workflow through the bundled MCP helper.
2. A new connection returns no mail before approval and external-processing
   disclosure in Unwired. Approved requests run without repeated consent prompts.
3. Requests cannot cross the approved Profile, selected Mailbox Connections, or
   action permissions, including after the app switches Profile or grants shrink.
4. Connections persist across agent sessions on one Mac. Another Mac or Product
   Account does not inherit them.
5. Disabling a connection blocks subsequent access while preserving saved Drafts.
   Account removal still applies the existing account purge rules.
6. The helper launches Unwired when needed and works with its windows closed.
   Unavailable Macs, locked content, and unauthorized account states expose no mail.
7. Search pages have stable references and short previews. Selected reads can
   fetch uncached bodies; partial results and omitted content are explicit.
8. Provider unavailability permits clearly identified cached reads and local
   Draft work. It does not produce a false complete-search or successful-save result.
9. Agents create new-message, Reply, and Reply All Drafts with an in-scope sending
   mailbox, and cannot edit another connection's or the user's existing Drafts.
10. A stale agent edit preserves the user's current Draft and reports a conflict.
11. Retrying a creation or edit after a lost response produces one logical result.
12. Reading leaves read state unchanged. Agent requests cannot send, delete,
    organize mail, retrieve attachment contents, or change attachments.
13. Activity history records permitted metadata, excludes sensitive content,
    expires entries after 30 days, and supports clearing history.

These are required future checks, not verification results from this interview.
Settings visual design requires the repository's Figma-first review and user
approval before UI implementation.
