import * as Schema from 'effect/Schema';

import type { Asset } from './semantic-document.ts';

import {
  AssetSchema,
  imagesOf,
  SemanticDocumentSchema,
} from './semantic-document.ts';

const RecipientSchema = Schema.Struct({
  name: Schema.optionalKey(Schema.NonEmptyString),
  address: Schema.NonEmptyString,
});
export type Recipient = typeof RecipientSchema.Type;

// What a reply or forward answers: the received message and, for a reply, the RFC 5322 threading
// headers the sent reply carries and the Gmail thread of the mailbox that received it. A forward
// starts a conversation of its own.
const ResponseSchema = Schema.Union([
  Schema.Struct({
    kind: Schema.Literals(['reply', 'replyAll']),
    message: Schema.NonEmptyString,
    thread: Schema.Struct({
      connection: Schema.NonEmptyString,
      id: Schema.NonEmptyString,
    }),
    inReplyTo: Schema.optionalKey(Schema.NonEmptyString),
    references: Schema.Array(Schema.NonEmptyString),
  }),
  Schema.Struct({
    kind: Schema.Literal('forward'),
    message: Schema.NonEmptyString,
  }),
]);
export type Response = typeof ResponseSchema.Type;

// An unsent outgoing message kept on this device until it is discarded. It names the Mailbox
// Connection it sends from and that connection's address when chosen, so a later removal never
// silently substitutes another sender.
export const DraftSchema = Schema.Struct({
  id: Schema.NonEmptyString,
  connection: Schema.NonEmptyString,
  from: Schema.NonEmptyString,
  to: Schema.Array(RecipientSchema),
  cc: Schema.Array(RecipientSchema),
  bcc: Schema.Array(RecipientSchema),
  // Cc and Bcc stay shown once revealed or holding a recipient.
  copies: Schema.optionalKey(Schema.Literal(true)),
  // Text still being typed in To, Cc or Bcc, kept so an interruption never loses it.
  entries: Schema.optionalKey(
    Schema.Struct({
      to: Schema.optionalKey(Schema.NonEmptyString),
      cc: Schema.optionalKey(Schema.NonEmptyString),
      bcc: Schema.optionalKey(Schema.NonEmptyString),
    }),
  ),
  conflict: Schema.optionalKey(Schema.Literal(true)),
  subject: Schema.String,
  body: SemanticDocumentSchema,
  // Files attached apart from the body's inline images, in the order added.
  attachments: Schema.optionalKey(Schema.Array(AssetSchema)),
  // The received message a reply or forward answers, in the Draft's own Mailbox Connection.
  response: Schema.optionalKey(ResponseSchema),
  // The answered correspondence, kept apart from the authored body and never edited with it.
  quoted: Schema.optionalKey(SemanticDocumentSchema),
  // Milliseconds since 1970 of the last edit.
  updatedAt: Schema.Finite,
});
export type Draft = typeof DraftSchema.Type;
const equivalentDraft = Schema.toEquivalence(DraftSchema);
export const sameContent = (
  left: Draft | undefined,
  right: Draft | undefined,
) =>
  left === undefined || right === undefined
    ? left === right
    : equivalentDraft({ ...left, updatedAt: 0 }, { ...right, updatedAt: 0 });
// A Draft as its Product Sync record last held it on this device: the base that tells which side
// changed since. `version` identifies a sealed record revision; an older confirmed record served
// again is refused. `updatedAt` is Convex's compare-and-set revision. A first publication is stored
// without one; later writes retain their exact pending payload beside the confirmed version floor.
export const SyncedSchema = Schema.Struct({
  id: Schema.NonEmptyString,
  draft: Schema.NullOr(DraftSchema),
  version: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
  updatedAt: Schema.optionalKey(Schema.Finite),
  pending: Schema.optionalKey(
    Schema.Struct({
      draft: DraftSchema,
      version: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
    }),
  ),
});
export type Synced = typeof SyncedSchema.Type;

export type SyncedAsset = Readonly<{
  id: string;
  digest: string;
  size: number;
}>;

// Every asset of a Draft: its attachments, then its inline images in reading order, the quoted
// correspondence's last.
export const assetsOf = (draft: Draft): readonly Asset[] => [
  ...(draft.attachments ?? []),
  ...imagesOf(draft.body),
  ...(draft.quoted === undefined ? [] : imagesOf(draft.quoted)),
];

// The complete assets a Draft names, as Product Sync stores them.
export const syncedAssets = (drafts: readonly Draft[]) => {
  const assets = new Map<string, SyncedAsset>();
  for (const draft of drafts) {
    for (const asset of assetsOf(draft)) {
      if (asset.state === 'complete') {
        assets.set(`${asset.id}:${asset.digest}`, {
          id: asset.id,
          digest: asset.digest,
          size: asset.size,
        });
      }
    }
  }
  return assets;
};

export const sameDrafts = (left: readonly Draft[], right: readonly Draft[]) => {
  const byId = new Map(right.map((draft) => [draft.id, draft]));
  return (
    left.length === right.length &&
    left.every((draft) => {
      const other = byId.get(draft.id);
      return (
        other !== undefined &&
        other.updatedAt === draft.updatedAt &&
        sameContent(draft, other)
      );
    })
  );
};

// The largest file a Draft accepts, as for received attachments.
export const assetLimit = 25 * 1024 * 1024;

export const ImportedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  size: Schema.Int.check(
    Schema.isGreaterThanOrEqualTo(0),
    Schema.isLessThanOrEqualTo(assetLimit),
  ),
  digest: Schema.String.check(Schema.isPattern(/^[\da-f]{64}$/u)),
});
