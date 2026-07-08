import { defineSchema, defineTable } from 'convex/server';
import { v } from 'convex/values';

export default defineSchema({
  productAccounts: defineTable({
    createdAt: v.number(),
    lastSeenAt: v.number(),
    tokenIdentifier: v.string(),
  }).index('by_tokenIdentifier', ['tokenIdentifier']),

  trustedDevices: defineTable({
    deviceIdentifier: v.string(),
    lastSeenAt: v.number(),
    platform: v.string(),
    productAccountId: v.id('productAccounts'),
    registeredAt: v.number(),
  })
    .index('by_productAccountId', ['productAccountId'])
    .index('by_productAccountId_and_deviceIdentifier', [
      'productAccountId',
      'deviceIdentifier',
    ]),
});
