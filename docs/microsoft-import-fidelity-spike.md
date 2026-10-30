# Microsoft mailbox import fidelity spike

[#1340](https://github.com/unwired-dev/product/issues/1340) asks whether the
hosts can put a local EML or MBOX message into a personal Outlook.com or
work/school Microsoft 365 mailbox as received mail, and with what fidelity. It
changes no runtime scope or credential. Official sources were read on
2026-10-30.

## Result

Microsoft Graph, which the hosts already use
([Microsoft mail](microsoft-mail.md)), has no supported way to import received
mail from MIME. IMAP `APPEND` over OAuth is the candidate identified for both
account types. It needs additional consent for IMAP access and IMAP enabled on
the mailbox.

This is an inference from the reviewed documentation, pending the blocked
[live proof](#live-proof). The proof decides whether IMAP preserves enough for
EML and MBOX import. Runtime import remains a separate follow-up.

## Microsoft Graph

- **Creating a message from MIME makes a Draft.**
  [Create message](https://learn.microsoft.com/en-us/graph/api/user-post-messages?view=graph-rest-1.0)
  can "Create a draft of a new message in either JSON or MIME format" under
  the hosts' existing `Mail.ReadWrite`. The base64 MIME body is saved in Drafts
  or in a named folder. The documented responses show `"isDraft": true` and a
  `receivedDateTime` set at creation. The MIME guide lists Draft creation and
  sending operations, and says "Microsoft Graph does not support editing or updating MIME
  properties individually"
  ([send MIME](https://learn.microsoft.com/en-us/graph/outlook-send-mime-message)).
- **Mailbox import and export is not EML import.** The
  [import how-to](https://learn.microsoft.com/en-us/graph/import-exchange-mailbox-item)
  takes an item "that was exported using exportItems" as a "base64 encoded FTS
  format" stream, not MIME. Microsoft states these APIs "aren't designed for
  mailbox backup and restore"
  ([overview](https://learn.microsoft.com/en-us/graph/api/resources/mailbox-import-export-api-overview)).
  [createImportSession](https://learn.microsoft.com/en-us/graph/api/mailbox-createimportsession?view=graph-rest-1.0)
  needs `MailboxItem.ImportExport` for work/school accounts and is "Not
  supported" for personal Microsoft accounts.
- **EWS is retiring.** Exchange Online began disabling EWS on 2026-10-01 and
  turns it off fully in April 2027
  ([EWS retirement timeline](https://techcommunity.microsoft.com/blog/exchange/exchange-online-ews-your-time-is-almost-up/4492361)).

## IMAP

[OAuth for IMAP](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth)
"is available for both Microsoft 365 ... and Outlook.com users" through SASL
`XOAUTH2` with the delegated scope
`https://outlook.office.com/IMAP.AccessAsUser.All`. Its resource is Outlook,
not Graph, so the hosts would need additional consent and a separate token. The public-client
Microsoft Entra app would also need the permission. Work/school tenant consent
policy can require administrator approval
([app consent policies](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/manage-app-consent-policies)).
No backend or app-only credential is involved.

The [IMAP standards support](https://learn.microsoft.com/en-us/openspecs/exchange_standards/ms-stanximap/7513f9b5-501b-4f96-9fd8-0fdb3432d1e7)
document covers Exchange Server 2007 through Subscription Edition, not
Exchange Online or Outlook.com. Its behavior below is a baseline to test, not
service-specific support evidence.

- **Enablement.** Outlook.com disables POP and IMAP by default. The person turns
  on **Let devices and apps use IMAP**
  ([Outlook.com settings](https://support.microsoft.com/en-us/outlook/pop-imap-and-smtp-settings-for-outlook-com)).
  Microsoft 365 enables IMAP for new mailboxes, and administrators can turn it
  off per mailbox
  ([email apps](https://learn.microsoft.com/en-us/exchange/recipients-in-exchange-online/manage-user-mailboxes/managing-email-apps-for-user-mailboxes)).
- **What `APPEND` carries.** [RFC 3501 §6.3.11](https://www.rfc-editor.org/rfc/rfc3501#section-6.3.11)
  `APPEND` takes the message literal, a flag list and an internal date. The
  Exchange Server document lists no `APPEND` deviation except when `EXISTS` is
  sent (§2.2.22). It also says "Microsoft Exchange does not support client-defined
  keywords" (§2.2.4). Preservation of source keywords and labels is therefore
  unproven for the services.
- **Byte-exact readback is not guaranteed.** "Outlook _does not save_ messages in MIME
  format"
  ([get MIME](https://learn.microsoft.com/en-us/graph/outlook-get-mime-message)).
  Exchange Server sizes messages by storage by default, not by the exact MIME
  size (§2.2.5).
  Fidelity must be checked by headers, parts and attachment hashes, not bytes.
- **Folders.** Exchange Server documents `/` as the hierarchy delimiter, up to
  31 levels and names of up to 250 characters (§2.2.7). Check the services' `LIST`
  responses and folder behavior before adopting those limits.
- **Size.** Microsoft 365 mailboxes receive up to 36 MB by default, and
  administrators can set 1 to 150 MB
  ([Exchange Online limits](https://learn.microsoft.com/en-us/office365/servicedescriptions/exchange-online-service-description/exchange-online-limits)).
  These are message transport limits, not a proven `APPEND` ceiling. The reviewed
  sources establish no `APPEND` size limit for either account type.
- **Ambiguous outcome.** The standards document covers only RFC 3501, so
  `UIDPLUS` support must be checked with `CAPABILITY`. After a lost tagged
  response, search the target folder for the source `Message-ID` and verify a
  unique match against the fixture before confirming insertion. Zero matches,
  multiple matches or a missing ID leave the outcome unknown and do not authorize
  automatic retry. Exchange Server documents only US-ASCII `SEARCH` (§2.2.24);
  check the services separately.

## Live proof

Not run. Protected Outlook.com and Microsoft 365 test mailboxes are not
available ([#1104](https://github.com/unwired-dev/product/issues/1104)), and no
protected workflow runs an import probe. Microsoft tokens stay inside the native
device boundary. With one synthetic mailbox of each type and IMAP enabled, the
authorized operator:

1. Builds synthetic EML fixtures with unique `Message-ID`s: plain text,
   `multipart/alternative`, a binary attachment with a recorded SHA-256, an
   RFC 2047 encoded subject and a past `Date`. Include two messages extracted
   from a synthetic MBOX, recording their MIME hashes before insertion.
2. Grants the probe
   `https://outlook.office.com/IMAP.AccessAsUser.All offline_access` and records
   the granted scopes.
3. Connects using TLS, authenticates with `XOAUTH2` and reads `CAPABILITY`, then
   creates a unique run folder and a nested folder. Uses `LIST` to verify their
   names and hierarchy, and appends fixtures to both with `(\Seen)` and their
   past `Date` converted to IMAP date-time syntax as the internal date.
4. Selects each target folder, finds each fixture with
   `UID SEARCH HEADER Message-ID "<fixture-id>"` and reads each candidate with
   `UID FETCH <uid> (FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[])`
   ([RFC 3501 §6.4.8](https://www.rfc-editor.org/rfc/rfc3501#section-6.4.8)).
   If the search finds nothing, it fetches every message in the run folder and
   matches the fixture by its stored `Message-ID` or, failing that, by its
   decoded body text and attachment hashes, so a search gap or a rewritten
   `Message-ID` is not mistaken for a missing message. Only a single match counts.
   Verifies the exact `Message-ID`, recording any rewrite, decoded headers, MIME parts and attachment
   hashes. Through the existing Graph grant, it locates the same message by
   `internetMessageId` in the corresponding folder and reads `isDraft`,
   `receivedDateTime` and `$value`, recording date differences explicitly.
5. Creates a fixture through Graph Create message in a separate control folder,
   as the Draft comparison, and records its returned `isDraft` and dates.
6. Uses a fresh fixture and `Message-ID` for the lost-response case. Drops the
   connection after sending its complete `APPEND` literal but before reading the
   tagged response, reconnects, selects the target folder and verifies matches
   as in step 4 without retrying the insertion.
7. Appends synthetic MIME fixtures of 10, 25, 35 and 40 MB, recording exact literal
   byte counts, acceptance or rejection and readback for accepted items. Deletes
   only the run's folders, children first, after recording verdicts; leaves the
   local fixtures unchanged. Never invokes a send operation.

Record only redacted run metadata, status codes, capability names, comparison
verdicts and hashes, never addresses or tokens. An authentication or policy
error, or a failed control, makes the run inconclusive. A passing run demonstrates
only the tested fixtures, sizes and mailbox policies. Record whether appended
messages are not Drafts and preserve their folder, internal date, `\Seen`, MIME
parts, attachment hashes and decoded source headers in both account types,
including every loss or normalization. It does not qualify general EML or MBOX
import or change runtime scope.
