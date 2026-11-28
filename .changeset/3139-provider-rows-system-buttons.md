---
'@private-email/mobile': patch
---

On iPhone and iPad, the mailbox provider rows in onboarding and in Add an IMAP Mailbox are system buttons, so VoiceOver reads each as one button with its detail as the hint and the system draws the press feedback (#3139).

At the largest text sizes, and after the text size changes while the list is open, the provider rows wrap their details instead of clipping them.
