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

Apply the [automatic-scanning contract](../../product/mail-commitments.md#automatic-scanning)
to deliberate master Assistance Off separately from involuntary system/model
interruptions. Preserving a saved scan choice does not admit disabled-period
history or pre-Off results after re-enable. ADR 0072 records the panel-selected
new-mail boundary; current consent, saved enablement and source ownership still
govern new work.

Synchronized human decisions constrain both new processing and materialized local
queues. Apply the [review-queue contract](../../product/mail-commitments.md#review-queue)
to persisted proposals, open review, acceptance and in-flight result publication,
including decision-before-record delivery and delayed offline observation.
Matching respects the reviewed obligation/proposal, source identities and target
without treating an entire Thread, message or commitment as one suppressed item.
This clarification selects no matching algorithm or new source-decision schema.

Retiring queues does not settle independent offline acceptances that already
created records. Apply the [record lifecycle contract](../../product/mail-commitments.md#record-and-lifecycle)
to their one-logical-record convergence, including conflicting authored values,
completion, deletion and references retained before reconciliation. Current
Profile ownership and source isolation still govern routes and reminders. This
adds no broader manual-record merge policy or identity/storage algorithm.

The [source-removal contract](../../product/mail-commitments.md#source-removal-and-profile-moves)
also requires disclosure before confirmation, including retained authored state
and existing deletion choices without revealing locked content. Direction is
separate from lifecycle state and remains part of both retention and disclosure.
Retention alone
does not satisfy that requirement.

Profile moves must also apply the canonical move outcome to reminder work already
scheduled, rather than only reparenting the accepted record. The
[source-removal and move contract](../../product/mail-commitments.md#source-removal-and-profile-moves)
owns reminder reassignment and reconciliation, including current target controls,
cancelled moves and delayed offline observation. This selects no scheduler or
remote-cancellation protocol.

## Qualification

The [canonical scenarios](../../product/mail-commitments.md#delivery-and-qualification)
require real iPhone, iPad and Mac evidence, real on-device recognition on eligible
hardware and real Private Sync journeys. Synthetic outputs and compiled bindings
remain distinct from that qualification.
