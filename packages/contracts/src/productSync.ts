import type { Infer } from 'convex/values';

import { v } from 'convex/values';

export const encryptedProductSyncPayloadBodyValidator = v.object({
  algorithm: v.literal('AES-GCM-256'),
  ciphertextBase64: v.string(),
  keyVersion: v.number(),
  nonceBase64: v.string(),
  schemaVersion: v.number(),
  tagBase64: v.string(),
});

export type EncryptedProductSyncPayloadBody = Infer<
  typeof encryptedProductSyncPayloadBodyValidator
>;

export const encryptedProductSyncPayloadValidator = v.object({
  encryptedPayload: encryptedProductSyncPayloadBodyValidator,
  payloadIdentifier: v.string(),
  updatedAt: v.number(),
});

export type EncryptedProductSyncPayload = Infer<
  typeof encryptedProductSyncPayloadValidator
>;

export const encryptedProductSyncPayloadPageValidator = v.object({
  continueCursor: v.string(),
  isDone: v.boolean(),
  page: v.array(encryptedProductSyncPayloadValidator),
});

export type EncryptedProductSyncPayloadPage = Infer<
  typeof encryptedProductSyncPayloadPageValidator
>;

export const encryptedProductSyncPayloadListResponseValidator = v.union(
  encryptedProductSyncPayloadPageValidator,
  v.array(encryptedProductSyncPayloadValidator),
);

export type EncryptedProductSyncPayloadListResponse = Infer<
  typeof encryptedProductSyncPayloadListResponseValidator
>;

export const encryptedProductSyncPayloadFixture: EncryptedProductSyncPayload = {
  encryptedPayload: {
    algorithm: 'AES-GCM-256',
    ciphertextBase64: 'Y2lwaGVydGV4dA',
    keyVersion: 1,
    nonceBase64: 'bm9uY2U',
    schemaVersion: 1,
    tagBase64: 'dGFn',
  },
  payloadIdentifier: 'fixture-payload-001',
  updatedAt: 1_781_200_000_000,
};

export const encryptedProductSyncPayloadPageFixture: EncryptedProductSyncPayloadPage =
  {
    continueCursor: '',
    isDone: true,
    page: [encryptedProductSyncPayloadFixture],
  };
