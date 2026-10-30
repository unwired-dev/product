# Microsoft mailbox import fidelity spike

[#1340](https://github.com/unwired-dev/product/issues/1340) asks whether the
hosts can put a local EML or MBOX message into a personal Outlook.com or
work/school Microsoft 365 mailbox as received mail, and with what fidelity. It
changes no runtime scope or credential. Official sources were read on
2026-10-30.

## Result

Microsoft Graph, which the hosts already use
([Microsoft mail](microsoft-mail.md)), has no supported way to import received
mail from MIME. The only documented candidate is IMAP `APPEND` over OAuth, for
both account types. It needs a second user consent and IMAP enabled on the
mailbox.

This is an inference from the reviewed documentation, pending the blocked
[live proof](#live-proof). The proof decides whether IMAP preserves enough for
EML and MBOX import. Runtime import remains a separate follow-up.

## Microsoft Graph

- **Creating a message from MIME makes a Draft.**
  [Create message](https://learn.microsoft.com/en-us/graph/api/user-post-messages?view=graph-rest-1.0)
  can "Create a draft of a new message in either JSON or MIME format" under
  the hosts' existing `Mail.ReadWrite`. The base64 MIME body is saved in Drafts
  or in a named folder. The documented responses show `"isDraft": true` and a
  `receivedDateTime` set at creation. The MIME guide lists only "Create draft
  messages" and says "Microsoft Graph does not support editing or updating MIME
  properties individually"
  ([send MIME](https://learn.microsoft.com/en-us/graph/outlook-send-mime-message)).
  Clearing the Draft state with extended properties appears only in community
  answers, not in Microsoft's references.
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
  ([EWS deprecation](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-ews-exchange-online)).

## IMAP

[OAuth for IMAP](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth)
"is available for both Microsoft 365 ... and Outlook.com users" through SASL
`XOAUTH2` with the delegated scope
`https://outlook.office.com/IMAP.AccessAsUser.All`. Its resource is Outlook,
not Graph, so the hosts would need a second consent and token. The public-client
Microsoft Entra app would also need the permission. No backend or app-only
credential is involved.

- **Enablement.** Outlook.com disables POP and IMAP by default. The person turns
  on **Let devices and apps use IMAP**
  ([Outlook.com settings](https://support.microsoft.com/en-us/outlook/pop-imap-and-smtp-settings-for-outlook-com)).
  Microsoft 365 enables IMAP for new mailboxes, and administrators can turn it
  off per mailbox
  ([email apps](https://learn.microsoft.com/en-us/exchange/recipients-in-exchange-online/manage-user-mailboxes/managing-email-apps-for-user-mailboxes)).
- **What `APPEND` carries.** RFC 3501 `APPEND` takes the message literal, a flag
  list and an internal date. Microsoft's
  [IMAP standards support](https://learn.microsoft.com/en-us/openspecs/exchange_standards/ms-stanximap/7513f9b5-501b-4f96-9fd8-0fdb3432d1e7)
  lists no `APPEND` deviation except when `EXISTS` is sent. It also says
  "Microsoft Exchange does not support client-defined keywords", so source
  keywords and labels are lost.
- **Readback is not byte-exact.** "Outlook _does not save_ messages in MIME
  format"
  ([get MIME](https://learn.microsoft.com/en-us/graph/outlook-get-mime-message)).
  Exchange sizes messages by storage by default, not by the exact MIME size.
  Fidelity must be checked by headers, parts and attachment hashes, not bytes.
- **Folders.** The hierarchy delimiter is `/`, with up to 31 levels and names of
  up to 250 characters.
- **Size.** Microsoft 365 mailboxes receive up to 36 MB by default, and
  administrators can set 1 to 150 MB
  ([Exchange Online limits](https://learn.microsoft.com/en-us/office365/servicedescriptions/exchange-online-service-description/exchange-online-limits)).
  Microsoft documents no `APPEND` limit and no Outlook.com limit.
- **Ambiguous outcome.** The standards document covers only RFC 3501, so
  `UIDPLUS` is not documented. After a lost tagged response, an importer must
  search the target folder for the source `Message-ID` before retrying. A message
  without one cannot be matched and must not be retried automatically. `SEARCH`
  supports only US-ASCII.

## Live proof

Not run. Protected Outlook.com and Microsoft 365 test mailboxes are not
available ([#1104](https://github.com/unwired-dev/product/issues/1104)), and no
protected workflow runs an import probe. Microsoft tokens stay inside the native
device boundary. With one synthetic mailbox of each type and IMAP enabled, the
authorized operator:

1. Builds synthetic EML fixtures with unique `Message-ID`s: plain text,
   `multipart/alternative`, a binary attachment with a recorded SHA-256, an
   RFC 2047 encoded subject and a past `Date`.
2. Grants the probe
   `https://outlook.office.com/IMAP.AccessAsUser.All offline_access` and records
   the granted scopes.
3. Reads `CAPABILITY` as a control, then creates a run folder and appends each
   fixture with `(\Seen)` and its `Date` as the internal date.
4. Reads each message back with
   `UID FETCH (FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[])`. Through the existing
   Graph grant, it reads `isDraft`, `receivedDateTime` and `$value`.
5. Creates the same fixture through Graph Create message in the run folder, as
   the Draft comparison.
6. Drops the connection after sending one `APPEND` literal, reconnects and
   counts matches for its `Message-ID`.
7. Appends synthetic fixtures of 10, 25, 35 and 40 MB, then deletes the run
   folder.

Record only redacted run metadata, status codes, capability names, comparison
verdicts and hashes, never addresses or tokens. An authentication or policy
error, or a failed control, makes the run inconclusive. The path is supported
when appended messages are not Drafts and keep their internal date, `\Seen`,
attachment hashes and source headers in both account types.
