# Privacy and sync: architecture notes

Reviewer-only companion to [docs/product/privacy-and-sync.md](../../product/privacy-and-sync.md).
Read under the [implementation and review workflow](../../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Scope

Privacy and encryption boundaries remain applicable. Category-Aware Notification
and Generic Notification Fallback retain prototype meanings; replacement
notification behavior comes from
[ADR 0063](../../adr/0063-notify-for-new-inbox-mail-without-categorization.md).

## Decisions and scope

- [Accepted replacement scope](../../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
- [End-to-end encrypted product sync](../../adr/0001-end-to-end-encrypted-product-sync.md)
- [Use local-first metadata and a bounded encrypted body cache](../../adr/0012-bounded-encrypted-body-cache.md)
- [Accept best-effort background mail freshness](../../adr/0013-best-effort-device-side-mail-freshness.md)
- [Sync mail workflow preferences, not device state](../../adr/0019-sync-mail-workflow-preferences-not-device-state.md)
- [Notify for new Inbox mail without categorization](../../adr/0063-notify-for-new-inbox-mail-without-categorization.md)

[The documentation index](../../README.md) explains ADR precedence and separates
current replacement work from prototype maintenance and historical plans.

## Local storage and background freshness

- The [2026-10-06 ADR 0029 amendment](../../adr/0029-sanitize-html-before-webkit-rendering.md#amendment--2026-10-06)
  accepts resolving all visible, sanitized CID references on explicit open within
  the existing per-message limits and shared presentation budget, without
  viewport admission. It also permits application-owned layout measurement in
  `WKContentWorld.defaultClientWorld` on both hosts while page JavaScript remains
  disabled. Sanitization, non-persistent WebKit storage, navigation cancellation
  and the prohibition on message-controlled scripts or bridges remain intact.
  Remote Message Content retains its consent, policy, viewport-plus-margin,
  isolated transport and separate-cache boundary under
  [#763](https://github.com/unwired-dev/product/issues/763).

- The Product Account mail-load coordinator permits at most four concurrent message-body pipelines account-wide and two per **Mailbox Connection**; a provider may lower only its own connection limit when its transport cannot safely multiplex

- Each **Mailbox Connection** has at most one speculative prefetch or historical-work lane, which yields immediately to interactive work and never occupies another connection's capacity

- A synchronization first computes a cache-fitting combined protected set: selected-recent candidates take priority in recency order, then bodies belonging to pinned **Threads** in most-recently-read Thread and message order, stopping when eligible eviction space is exhausted. Applying a new selection may drop an existing pin-only body protection to admit a selected-recent candidate; the dropped body then follows last-resort pinned-Thread eviction. Only admitted candidates are protected; candidates of the same selection never evict one another, and a candidate that still cannot free eligible space is refused and remains on demand until a later synchronization finds space

- One-message consent authorizes only the current remote retrieval and later encrypted-cache reuse for the same stable message presentation; it does not authorize changed content or a new request. Remote image requests use an isolated cookie-free and credential-free HTTPS path, reject any literal or resolved non-public destination, pin one validated public address while authenticating the original TLS hostname, and repeat that boundary for every redirect

- The remote-content limit is a shared quota only: entries use Product Account-, Mail Profile-, connection-, stable-message-, and resource-revision-scoped encryption and identity, never deduplicate across Profiles, become inaccessible with Profile Lock, and follow existing Profile-removal deletion rules
