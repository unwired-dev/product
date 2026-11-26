---
'@private-email/mobile': minor
'@private-email/mail-core': patch
---

On iPhone and iPad, the reader's sender menu offers Block Domain… under Block Sender…: its sheet blocks the sender's exact domain, with its subdomains or alone, and can exempt the person's contacts there. Settings › Blocked Senders lists each Mail Profile's Domains before its Addresses, shows an `xn--` domain with the characters it displays, and unblocks a domain by swipe or Edit. Mail core adds `offeredDomain`, `parentDomain`, `addressesAtDomain` and `shownDomain`.
