# Keep Follow-Up Nudges private and device-delivered

A Follow-Up Nudge is Profile-scoped product state for revisiting a sent Thread, not a Provider Mail Action and not a Read Receipt. The client creates one only after direct scheduling or explicit acceptance of an on-device suggestion. It never drafts, modifies, or sends a follow-up message.

Each active nudge is stored as an opaque End-to-End Encrypted Product Sync record keyed by Stable Thread Identity. The encrypted payload contains the due instant, sent-message anchor, messages already observed when the nudge was created, the normalized authorized Sending Identity set, and the Trusted Device that owns the Return-to-Attention request. Cancellation uses a retained tombstone, and same-entity changes converge by the existing deterministic record-family contract.

Reply detection runs on trusted devices against locally observed metadata. A new message in the anchored Thread cancels the nudge only when it was not present at creation, is not provider Sent state, and its sender is outside the recorded authorized identity set. This keeps aliases from cancelling their own nudge and does not treat Read Receipt state as reply evidence.

The due state remains visible until a reply or explicit cancellation. Notification denial, Quiet, Profile Lock, or privacy policy can suppress the interruption without completing the nudge. Only the current owner device may deliver a notification, and lock-screen content follows the existing device-local presentation preference.

Older clients ignore the additive Follow-Up record prefix. They cannot erase the encrypted nudge by reading or rewriting older Product Sync record families, while compatible devices continue to converge and preserve overdue state offline.
