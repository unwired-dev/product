---
'@private-email/mobile': patch
'@private-email/macos': patch
---

Announce Send outcomes to VoiceOver on iPhone, iPad and Mac. Each change of where
an Outbox message stands, and each Check Again answer that leaves delivery unknown,
is announced once however many Mac windows show it. The composer announces a refused Send, a Draft that
could not be saved on Close or Discard, and the Discard question.

Outbox status and Check Again announcements wait for existing VoiceOver speech.
