---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/macos': patch
---

On the Mac, a message with a one-click unsubscribe offer shows an Unsubscribe banner naming its mailing list, and **Unsubscribe…** in the reader's More menu. **Unsubscribe…** asks first, naming the list and the receiving address, and only **Unsubscribe** sends the request, once. The banner then says the request was sent, dated, or that it failed or got no clear answer, with **Try Again**, which sends again without asking, and **Block Sender…**. A list the Mail Profile asked to leave in the 14 days before the message arrived shows as sent. A message whose only offer is `mailto:` shows neither yet (#2967). The theme gains `fillBanner`, the banner's opaque fill.
