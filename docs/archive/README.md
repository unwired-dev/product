# Historical documents

These records preserve earlier decisions and implementation context. The
prototype plans were archived during the 2026-09-09 rewrite documentation audit;
domain discussions were moved here on 2026-09-28. Use
[the active documentation index](../README.md) for current work.

| Document                                                                            | Why it is historical                                                                                                                  |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| [Bootstrap review](bootstrap-review.md)                                             | The initial bootstrap exists; the replacement has a different host architecture.                                                      |
| [Settings redesign](settings-redesign.md)                                           | Describes the Swift/Catalyst destination model and prototype feature set.                                                             |
| [Client stability and composer redesign](client-stability-and-composer-redesign.md) | Diagnoses and redesigns the old client; replacement tickets own new implementation.                                                   |
| [Scheduled Send and Send Reminder](scheduled-send.md)                               | Uses cross-device takeover; accepted future scheduling retains originating-device ownership.                                          |
| [IMAP/SMTP library offload](imap-smtp-library-offload.md)                           | Research for replacing handwritten Swift transports, already superseded by SwiftMail adoption.                                        |
| [SwiftMail alternatives](swiftmail-alternatives.md)                                 | Historical Swift dependency comparison, not a React Native binding qualification.                                                     |
| [Official provider SDKs](official-mail-provider-sdks.md)                            | Apple/Swift SDK research predating the new independent native host graphs.                                                            |
| [Domain discussions](domain-discussions.md)                                         | Earlier example dialogues and ambiguity resolutions; topic glossaries and accepted ADRs now own the active definitions and decisions. |

Future IMAP/SMTP work starts at [#629](https://github.com/unwired-dev/product/issues/629),
Microsoft work at [#633](https://github.com/unwired-dev/product/issues/633), and
Profile work at [#644](https://github.com/unwired-dev/product/issues/644).
[Send Reminders #658](https://github.com/unwired-dev/product/issues/658) and
[scheduled delivery #659](https://github.com/unwired-dev/product/issues/659)
follow the new delivery boundary. See [all tickets](../qualification/expo-rewrite-ticket-coverage.md)
for the complete agreed scope.
