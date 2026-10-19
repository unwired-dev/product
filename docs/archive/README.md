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

Use the [power-user launch specification](../product/power-user-launch.md) for
current provider, Profile and deferred-feature scope, and
[GitHub issues](https://github.com/unwired-dev/product/issues) for completion
and dependencies. The archive is not a live roadmap.
