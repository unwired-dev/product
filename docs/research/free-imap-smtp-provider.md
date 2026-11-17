# Free hosted IMAP and SMTP candidate

Researched 2026-11-17 using official provider sources. Documentation research only;
no account creation, authentication or product qualification was performed.

## Recommendation and scope

The owner selected **Seznam Email** on 2026-11-17, using a dedicated owner-managed mailbox containing
only synthetic mail. **GMX.com is the conditional fallback**, subject to successful
signup from the operator's country. This is a practical recommendation based on
the documented transports, password support and signup requirements below.

The [approved scope amendment](../adr/0069-expand-the-apple-launch-to-power-user-mail.md#imap-and-smtp-certification-amendment-2026-11-17)
replaces Fastmail as a required launch certification target.
[#1103](https://github.com/unwired-dev/product/issues/1103) requests dedicated
iCloud Mail and Seznam Email synthetic accounts, a controlled standards server, an
authorized operator and a protected execution/access path.
[#632](https://github.com/unwired-dev/product/issues/632) and
[ADR 0069](../adr/0069-expand-the-apple-launch-to-power-user-mail.md) explicitly
require iCloud Mail and Seznam Email qualification. The decision does not satisfy
that requirement without actual redacted evidence on
both maintained Apple hosts. The
[existing catalog](../imap-mailboxes.md#catalogued-providers) already lists
Seznam, GMX, WEB.DE and Yahoo; catalog inclusion is not certification.

## Practical candidates

- **Seznam Email:** Seznam accounts are
  [free](https://o-seznam.cz/sluzby/ucet/), and its
  [mail-client guide](https://o-seznam.cz/napoveda/email/mohlo-by-se-hodit/postovni-programy-a-aplikace/)
  documents `imap.seznam.cz:993` with implicit TLS and
  `smtp.seznam.cz:465` with implicit TLS and required SMTP authentication.
  [Mail-client password guidance](https://o-seznam.cz/napoveda/ucet/dvoufazove-overeni/postovni-programy/)
  requires a separate IMAP/SMTP password when two-factor authentication is enabled.
  [New-mailbox signup](https://o-seznam.cz/napoveda/ucet/registrace/ucet-s-novou-emailovou-schrankou/)
  requires SMS verification. Numbers outside +420/+421 follow a
  [different verification process](https://o-seznam.cz/napoveda/ucet/registrace/zahranicni-telefonni-cislo/),
  sending an SMS to Seznam within five minutes. This makes Seznam the best first
  evaluation for a Czech operator, provided an authorized recovery number is
  available. No complete country eligibility list or explicit permission for
  automated qualification was verified.
- **GMX.com:** Offers a
  [free account](https://www.gmx.com/mail/create-email-address/) and documents
  [`imap.gmx.com:993`, `mail.gmx.com:465` or `:587`](https://support.gmx.com/pop-imap/imap/server.html),
  respectively implicit TLS, implicit TLS and STARTTLS. Enable
  [POP3/IMAP access](https://support.gmx.com/pop-imap/toggle.html) first; GMX can
  disable it after prolonged non-use. It supports
  [application-specific passwords](https://support.gmx.com/security/2fa/application-specific-passwords.html).
  [Signup](https://support.gmx.com/account/login-details/register.html) requires
  personal details, a mobile number and a human verification challenge;
  [country/IP restrictions](https://support.gmx.com/account/login/signup-error.html)
  apply, without a published complete allowlist in that guide. Czech signup
  eligibility remains unverified. Do not confuse this with GMX's German service,
  whose [registration guide](https://hilfe.gmx.net/account/logindaten/registrierung.html)
  currently lists German, Austrian or Swiss mobile prefixes.
- **WEB.DE:** Its [FreeMail tier](https://web.de/email/) costs €0 and includes
  mail-client access. [Settings](https://hilfe.web.de/pop-imap/imap/imap-serverdaten.html)
  specify `imap.web.de:993` with implicit TLS and `smtp.web.de:587` with STARTTLS,
  alternatively `:465` with implicit TLS. Access must be
  [enabled](https://hilfe.web.de/email/einstellungen/pop3-imap-einschalten.html).
  [Signup](https://hilfe.web.de/account/logindaten/registrierung.html) requires a
  valid German or Swiss mobile number and SMS verification. That is a poor fit
  for an operator with only a Czech number. Current app-password requirements
  were not independently verified.
- **Yahoo:** Its official
  [IMAP settings](https://help.yahoo.com/kb/imap-settings-sln4075.html) document
  `imap.mail.yahoo.com:993` with SSL, `smtp.mail.yahoo.com:465` or `:587` with SSL,
  full-address authentication and a generated app password. Prefer documented
  implicit TLS on 465 here. Free-tier entitlement, current signup country/phone
  restrictions and app-password issuance for a fresh account remain unverified;
  direct Help fetches returned HTTP 429, although the settings were available in
  the official search result. Keep Yahoo behind Seznam and GMX pending those checks.

## Exclusions for this evaluation

- [Proton Free](https://proton.me/support/imap-smtp-and-pop3-setup) lacks Bridge,
  which requires a paid plan and is a desktop intermediary.
  [Tuta](https://tuta.com/support/howto) does not offer third-party IMAP/SMTP access.
- [Zoho Mail Free](https://www.zoho.com/mail/compare/overview.html) excludes
  IMAP/POP/ActiveSync. Its
  [generic server guide](https://www.zoho.com/mail/help/imap-access.html?src=mail-options)
  still mentions personal/free accounts, so do not infer a new free account's
  entitlement from published endpoints.
  [mail.com](https://support.mail.com/pop-imap/imap/imap.html) reserves
  IMAP/SMTP for Premium.
- Gmail is not technically excluded: eligible accounts can use
  [app passwords with two-step verification](https://support.google.com/mail/answer/185833?hl=en).
  It adds account-security prerequisites and is not the recommended independent
  candidate. [Outlook.com](https://support.microsoft.com/en-gb/outlook/pop-imap-and-smtp-settings-for-outlook-com)
  documents OAuth2/Modern Auth for IMAP and SMTP, so it is unsuitable for this
  password-based evaluation.

## Remaining evidence

Synthetic **message content** does not establish permission to invent signup
identity details or automate account provisioning. Suitability for a small,
operator-run test mailbox is an assessment, not provider approval for unattended,
bulk or failure-injection testing. Explicit provider permission, applicable usage
limits, retention/inactivity rules and recovery ownership still need confirmation.
Keep destructive and fault-injection cases on the controlled standards server.

The operator must establish both logins and verify role
mapping, receive/read/organize/search/attachments, SMTP submission, Sent-copy
reconciliation and recovery on the maintained hosts, with local credentials and
redacted evidence as required by [#632](https://github.com/unwired-dev/product/issues/632).
No provider capability set, successful TLS handshake or documentation entry proves
that complete product flow. None was exercised in this research.
