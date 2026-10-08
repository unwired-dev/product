---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Keep Gmail fresh across app lifecycles. On Mac, synchronization continues every five minutes after the last window closes and stops on Quit, with no helper process. On iPhone and iPad, a five-minute fallback poll runs while active, a background task synchronizes during the refresh opportunities iOS grants, and becoming active always catches up. Each run verifies registration and resumes from each mailbox's committed checkpoint. A shared wake-hint handler reads only a hint's opaque route and synchronizes only that mailbox. It never keeps Gmail's history ID or address, and ignores unknown or removed routes.
