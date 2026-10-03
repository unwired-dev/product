# Architecture decision records

Reviewer-only under the [implementation and review workflow](../agents/implementation-review.md).
The [architecture index](../architecture/README.md) routes the replacement
decisions and evidence.

## Numbering

ADR filenames are stable and never renumbered. Some numbers were issued more than
once: 0046 and 0049 are each used by two ADRs, 0050 by four and 0051 by three.
Each file is a separate decision, so the number alone does not identify an ADR.
Cite these ADRs with their number and title, and link the full filename. New
ADRs take the next number after the highest in this index.

## Index

| Number | Decision                                                                                                                                       |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| 0001   | [End-to-end encrypted product sync](0001-end-to-end-encrypted-product-sync.md)                                                                 |
| 0002   | [Device-held mail provider tokens with push relay](0002-device-held-mail-provider-tokens-with-push-relay.md)                                   |
| 0003   | [TypeScript, Effect, and Convex backend](0003-typescript-effect-convex-backend.md)                                                             |
| 0004   | [SwiftData for local persistence](0004-swiftdata-for-local-persistence.md)                                                                     |
| 0005   | [App-level encryption for sensitive local cache](0005-app-level-encryption-for-sensitive-local-cache.md)                                       |
| 0006   | [Local metadata search and provider full-text search](0006-local-metadata-search-provider-full-text-search.md)                                 |
| 0007   | [Classification engine interface](0007-classification-engine-interface.md)                                                                     |
| 0008   | [Device-evaluated Category-Aware Notifications](0008-device-evaluated-category-aware-notifications.md)                                         |
| 0009   | [Keep thread identity scoped to one mailbox connection](0009-mailbox-scoped-thread-identity.md)                                                |
| 0010   | [Keep mailbox authorization device-local](0010-device-local-mailbox-authorization.md)                                                          |
| 0011   | [Preserve provider-native mail adapters](0011-provider-native-mail-adapters.md)                                                                |
| 0012   | [Use local-first metadata and a bounded encrypted body cache](0012-bounded-encrypted-body-cache.md)                                            |
| 0013   | [Accept best-effort background mail freshness](0013-best-effort-device-side-mail-freshness.md)                                                 |
| 0014   | [Require trustworthy mailbox role mapping](0014-explicit-mailbox-role-mapping.md)                                                              |
| 0015   | [Queue provider mail actions optimistically](0015-optimistic-durable-provider-actions.md)                                                      |
| 0016   | [Model Outbox delivery as immutable attempts](0016-durable-outbox-delivery-attempts.md)                                                        |
| 0017   | [Require secure mail transport](0017-require-secure-mail-transport.md)                                                                         |
| 0018   | [Set a local mail performance budget](0018-local-mail-performance-budget.md)                                                                   |
| 0019   | [Sync mail workflow preferences, not device state](0019-sync-mail-workflow-preferences-not-device-state.md)                                    |
| 0020   | [Revoke devices with Product Sync key rotation](0020-revoke-devices-with-sync-key-rotation.md)                                                 |
| 0021   | [Delete Product Accounts immediately](0021-delete-product-accounts-immediately.md)                                                             |
| 0022   | [Save workflow preferences offline with explicit conflicts](0022-save-workflow-preferences-offline-with-explicit-conflicts.md)                 |
| 0023   | [Pin Threads instead of messages](0023-pin-threads-instead-of-messages.md)                                                                     |
| 0024   | [Allow multiple Categories per message](0024-allow-multiple-categories-per-message.md)                                                         |
| 0025   | [Use semantic rich-text Drafts with encrypted assets](0025-use-semantic-rich-text-drafts-with-encrypted-assets.md)                             |
| 0026   | [Allow legacy TLS versions](0026-allow-legacy-tls-versions.md)                                                                                 |
| 0027   | [Use a qualified third-party mail protocol engine](0027-qualified-third-party-mail-protocol-engine.md)                                         |
| 0028   | [Restore the TLS 1.2 minimum](0028-restore-tls-1-2-minimum.md)                                                                                 |
| 0029   | [Sanitize message HTML before isolated WebKit rendering](0029-sanitize-html-before-webkit-rendering.md)                                        |
| 0030   | [Gate incoming attachment downloads in message presentation](0030-gate-incoming-attachment-downloads.md)                                       |
| 0031   | [Refresh On-Premises Exchange Connection OAuth authorization on device](0031-refresh-ews-oauth-on-device.md)                                   |
| 0032   | [Use only synthetic mail in test environments](0032-use-only-synthetic-mail-in-test-environments.md)                                           |
| 0033   | [Bootstrap mail tests without external Product Account authentication](0033-bootstrap-mail-tests-without-external-product-authentication.md)   |
| 0034   | [Use GreenMail standalone for local mail testing](0034-use-greenmail-standalone-for-local-mail-testing.md)                                     |
| 0035   | [Isolate mail testing in harness-owned simulators](0035-isolate-mail-testing-in-harness-owned-simulators.md)                                   |
| 0036   | [Generate mail-test certificates per environment](0036-generate-mail-test-certificates-per-environment.md)                                     |
| 0037   | [Keep mail-test control outside the app](0037-keep-mail-test-control-outside-the-app.md)                                                       |
| 0038   | [Use a dedicated Google Workspace test tenant](0038-use-a-dedicated-google-workspace-test-tenant.md)                                           |
| 0039   | [Isolate Gmail testing in a Provider Test Project](0039-isolate-gmail-testing-in-a-provider-test-project.md)                                   |
| 0040   | [Split automated Gmail push testing at APNs](0040-split-automated-gmail-push-testing-at-apns.md)                                               |
| 0041   | [Broker provider compatibility through protected workflows](0041-broker-provider-compatibility-through-protected-workflows.md)                 |
| 0042   | [Fail closed when mail-test cleanup ownership is uncertain](0042-fail-closed-when-mail-test-cleanup-ownership-is-uncertain.md)                 |
| 0043   | [Make Inbox Cleanup reviewed and recoverable](0043-make-inbox-cleanup-reviewed-and-recoverable.md)                                             |
| 0044   | [Isolate standards-based unsubscribe actions](0044-isolate-standards-based-unsubscribe-actions.md)                                             |
| 0045   | [Keep contact and event content out of Product Sync](0045-keep-contact-and-event-content-out-of-product-sync.md)                               |
| 0046   | [Allowlist device-local diagnostics](0046-allowlist-local-diagnostics.md)                                                                      |
| 0046   | [Coordinate private Scheduled Send on trusted devices](0046-coordinate-private-scheduled-send-on-trusted-devices.md)                           |
| 0047   | [Stage mail-engine adoption before provider certification](0047-stage-mail-engine-adoption-before-provider-certification.md)                   |
| 0048   | [Separate encrypted Mail Profile ownership from legacy records](0048-separate-encrypted-mail-profile-ownership.md)                             |
| 0049   | [Synchronize category policy and learning generation](0049-synchronize-category-policy-and-learning-generation.md)                             |
| 0049   | [Use a risk-weighted test portfolio](0049-use-a-risk-weighted-test-portfolio.md)                                                               |
| 0050   | [Commit Mail Profile lifecycle changes atomically](0050-commit-mail-profile-lifecycle-atomically.md)                                           |
| 0050   | [Keep Thread Snooze out of provider state](0050-keep-thread-snooze-out-of-provider-state.md)                                                   |
| 0050   | [Scope each window to one Mail Profile](0050-scope-each-window-to-one-mail-profile.md)                                                         |
| 0050   | [Separate synchronized Quiet from device-local Profile Lock](0050-separate-synchronized-quiet-from-device-local-profile-lock.md)               |
| 0051   | [Enforce profile-scoped Blocked Senders on trusted devices](0051-enforce-profile-blocked-senders-on-trusted-devices.md)                        |
| 0051   | [Keep Follow-Up Nudges private and device-delivered](0051-keep-follow-up-nudges-private-and-device-delivered.md)                               |
| 0051   | [Synchronize Muted Threads as product state](0051-synchronize-muted-threads-as-product-state.md)                                               |
| 0052   | [Keep Mail Assistance on device and input-bound](0052-keep-mail-assistance-on-device-and-input-bound.md)                                       |
| 0053   | [Keep Mail Assistance enablement device-local](0053-keep-mail-assistance-enablement-device-local.md)                                           |
| 0054   | [Scope verified Sending Identities to Mail Profiles](0054-scope-verified-sending-identities-to-mail-profiles.md)                               |
| 0055   | [Integrate Profile-scoped Settings behind the release gate](0055-integrate-profile-settings-behind-release-gate.md)                            |
| 0056   | [ADR 0056: Keep the Google Gmail REST client internal-only](0056-keep-google-gmail-rest-client-internal-only.md)                               |
| 0057   | [Present composing inside the mail shell](0057-present-composing-inside-the-mail-shell.md)                                                     |
| 0058   | [Present Settings as independent navigation](0058-present-settings-as-independent-navigation.md)                                               |
| 0059   | [Replace the client for a shared cross-platform product](0059-replace-the-client-for-a-shared-cross-platform-product.md)                       |
| 0060   | [Pair mocked mail journeys with real integration evidence](0060-pair-mocked-mail-journeys-with-real-integration-evidence.md)                   |
| 0061   | [Separate product identity from registration mailbox authorization](0061-separate-product-identity-from-registration-mailbox-authorization.md) |
| 0062   | [Keep queued delivery on its originating device](0062-keep-queued-delivery-on-its-originating-device.md)                                       |
| 0063   | [Notify for new Inbox mail without categorization](0063-notify-for-new-inbox-mail-without-categorization.md)                                   |
| 0064   | [Isolate mobile and macOS native dependencies](0064-isolate-mobile-and-macos-native-dependencies.md)                                           |
| 0065   | [Scope Effect adoption](0065-scope-effect-adoption.md)                                                                                         |
