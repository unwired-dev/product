---
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': minor
'@private-email/mail-core': minor
---

Redesign onboarding, account setup and device trust on iPhone, iPad and Mac (#907).

- **Welcome and Sign In:** signed out, the app opens on a deep graphite Welcome with the cinnabar **Continue**. It leads to Sign In: **Sign in with Apple** in Apple's black or white button, then **Sign in with Google**, with the Private Sync fine print and the language choice. Mac and iPad show the brand panel beside the form; iPhone stacks the actions at the bottom and returns to Welcome with **Back**. A removed-device or deleted-account notice opens Sign In directly.
- **Connect your mail:** the first mailbox is chosen from provider rows: **Gmail**, **iCloud Mail**, **Microsoft 365 and Outlook** when the build supports it, **Fastmail** and **Other IMAP Account**. An IMAP row opens its form in place, and **Cancel** returns to the list. **Choose another Google mailbox** stays below the list. When Microsoft refuses the mailbox, its explanation shows as a warning notice above the providers. **Add an IMAP mailbox** on the account page uses the same rows.
- **IMAP form:** fields sit in labeled rows, grouped into the account, **Incoming (IMAP)** and **Outgoing (SMTP)**. SMTP security is a pair of choice chips, and blank SMTP credentials show **Same as incoming**. **Cancel** comes before the primary **Connect**.
- **Trust cards:** **Save your Recovery Key**, **Approve this device**, **Use your Recovery Key**, **Approve a new device**, **Unlock your device** and the **Remove “device”?** confirmation are alert-style cards with an icon, a centered title and description, and a primary or destructive action. Recovery Keys and approval codes sit on a quiet tile.
- **Buttons:** account and registration buttons use the design's quiet fill, with the accent fill for each step's primary action and destructive text for **Decline** and **Remove**.
- **Mail core:** the theme adds the `appleButton` and `appleOnButton` colors for Sign in with Apple in Light and Dark.
