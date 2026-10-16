---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Give the Registration gate one view model: `registrationScreen(t, state, choice)`
in `@private-email/mail-core/registration` returns the gate's destination, copy,
actions with their labels, the Product Account's identity and Sign-In Providers,
Mailbox Connections and private sync state. It also normalizes the Inbox choice.
Each host window stores the returned choice, so a choice invalidated by sign-out,
another Product Account or new setup is forgotten and cannot return with an
earlier snapshot. The individual copy and action helpers are now private to
mail-core. Mail-core modules import the registration snapshot model from
`registration-snapshot.ts` instead of the store.
