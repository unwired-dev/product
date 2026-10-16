---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Keep Outbox status and unknown-delivery recovery in the mail-core Outbox store.
Hosts read entries through `outbox.subscribe` and `outbox.getSnapshot`, whose
entries carry the Check Again state (`idle`, `checking` or `unconfirmed`), and
word them with `outboxCopy(t, entry, provider)`. Every Mac window now shows the
same Check Again progress and answer; the Edit warning stays local to its window.
A pending check no longer publishes its answer once the message leaves the Outbox,
is sent again or belongs to another Product Account.
