# Mail Commitments: architecture notes

Reviewer-only companion to
[the confirmed post-launch requirements](../../product/mail-commitments.md).
Read under the [implementation and review workflow](../../agents/implementation-review.md).

## Scope and decisions

[ADR 0072](../../adr/0072-allow-reviewed-post-launch-mail-commitments.md) records
the user-authorized exceptions for automatic analysis, a persistent local review
queue and authored-record retention after source/mailbox removal. It creates no
power-user launch gate and claims no implementation or release evidence.

Apply existing account/device trust, native key custody, encrypted local storage
and opaque Private Sync boundaries. The model returns proposals; persistence,
review decisions and accepted-record mutation remain separate responsibilities.
Do not synchronize unaccepted output, copy complete source bodies into proposals
or grant provider/network access to inference. Accepted records remain owned by
one Profile and source access remains confined to that owner.

The product contract governs independent/conflicting edits, deletion, source loss,
reviewed mixed-source moves, date semantics and reminder behavior. Implementation
must preserve these requirements through interruption, relaunch and synchronization,
including stale-result and stale-write rejection. This record selects no new wire
schema, storage quota or conflict-resolution protocol.

Synchronized human decisions constrain both new processing and materialized local
queues. Apply the [review-queue contract](../../product/mail-commitments.md#review-queue)
to persisted proposals, open review, acceptance and in-flight result publication,
including decision-before-record delivery and delayed offline observation.
Matching respects the reviewed obligation/proposal, source identities and target
without treating an entire Thread, message or commitment as one suppressed item.
This clarification selects no matching algorithm or new source-decision schema.

## Qualification

The [canonical scenarios](../../product/mail-commitments.md#delivery-and-qualification)
require real iPhone, iPad and Mac evidence, real on-device recognition on eligible
hardware and real Private Sync journeys. Synthetic outputs and compiled bindings
remain distinct from that qualification.
