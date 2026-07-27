import type { Infer } from 'convex/values';

import {
  devicePushRegistrationResponseValidator,
  gmailPushVerificationResponseValidator,
} from '@private-email/contracts/pushRelay';
import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import {
  action,
  internalAction,
  internalMutation,
  internalQuery,
  mutation,
  query,
} from './_generated/server.js';
import {
  gmailIdentityBindingDigest,
  gmailRoutingDigests,
  opaqueGmailConnectionId,
} from './gmailRouting.js';
import { requireAuthenticatedTrustedDevice } from './productAccountAuth.js';

const apnsEnvironmentValidator = v.union(
  v.literal('production'),
  v.literal('sandbox'),
);

const apnsRecipientValidator = v.object({
  apnsEnvironment: apnsEnvironmentValidator,
  apnsToken: v.string(),
  pushCleanupGeneration: v.number(),
  routeId: v.string(),
  trustedDeviceId: v.id('trustedDevices'),
});

const gmailOperationalConnectionStatusValidator = v.object({
  connectedAt: v.number(),
  lastVerifiedAt: v.number(),
  opaqueConnectionId: v.string(),
  trustedDeviceId: v.string(),
  updatedAt: v.number(),
});

type GmailOperationalConnectionStatus = Readonly<{
  connectedAt: number;
  lastVerifiedAt: number;
  opaqueConnectionId: string;
  trustedDeviceId: Id<'trustedDevices'>;
  updatedAt: number;
}>;

type ApnsRecipient = Readonly<{
  apnsEnvironment: Infer<typeof apnsEnvironmentValidator>;
  apnsToken: string;
  pushCleanupGeneration: number;
  routeId: string;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

const gmailPushVerificationSignalLifetimeMs = 10 * 60 * 1000;
const devicePushRouteInactivityLifetimeMs = 30 * 24 * 60 * 60 * 1000;
const devicePushRouteReconciliationBatchSize = 10;
const devicePushTokenCleanupBatchSize = 10;
const gmailPushProofCleanupBatchSize = 10;
const gmailPushVerificationBatchSize = 10;
const gmailActiveRouteInspectionLimit = 100;
const gmailConnectionLimitPerTrustedDevice = 20;
const gmailLegacyRouteFallbackLimit = 100;
const gmailLegacySignalMigrationLimit = 100;
const microsoftGraphConnectionLimitPerTrustedDevice = 20;
const microsoftGraphWakeupClaimLeaseMs = 5 * 60 * 1000;
const microsoftGraphWakeupMaximumAttempts = 5;
const microsoftGraphWakeupMaximumRetryDelayMs = 15 * 60 * 1000;
const microsoftGraphWakeupRetryBaseDelayMs = 60 * 1000;
const googleJsonWebKeySetUrl = 'https://www.googleapis.com/oauth2/v3/certs';
const googleSigningKeyFallbackLifetimeMs = 5 * 60 * 1000;
const googleSigningKeyMaximumLifetimeMs = 24 * 60 * 60 * 1000;
const googleSigningKeyFetchTimeoutMs = 10 * 1000;

type CachedGoogleSigningKeys = Readonly<{
  expiresAt: number;
  keys: ReadonlyMap<string, JsonWebKey>;
}>;

let cachedGoogleSigningKeys: CachedGoogleSigningKeys | null = null;

type VerifiedGoogleIdentity = Readonly<{
  emailAddress: string;
  providerAccountIdentifier: string;
}>;

function stringField(
  value: Readonly<Record<string, unknown>>,
  field: string,
): string | null {
  const candidate = value[field];
  return typeof candidate === 'string' && candidate.length > 0
    ? candidate
    : null;
}

function requiredString(value: string | null | undefined): string {
  if (value === null || value === undefined) {
    throw new Error('Gmail mailbox ownership proof rejected');
  }
  return value;
}

function isUnknownRecord(
  value: unknown,
): value is Readonly<Record<string, unknown>> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function decodeBase64Url(value: string): ArrayBuffer {
  const normalized = value.replaceAll('-', '+').replaceAll('_', '/');
  const padding = '='.repeat((4 - (normalized.length % 4)) % 4);
  const decoded = atob(`${normalized}${padding}`);
  const bytes = new Uint8Array(decoded.length);
  for (const [index, character] of [...decoded].entries()) {
    bytes[index] = character.codePointAt(0) ?? 0;
  }
  return bytes.buffer;
}

function decodeJwtRecord(value: string): Readonly<Record<string, unknown>> {
  try {
    const decoded: unknown = JSON.parse(
      new TextDecoder().decode(decodeBase64Url(value)),
    );
    if (isUnknownRecord(decoded)) {
      return decoded;
    }
  } catch {
    // The common rejection below intentionally does not disclose token contents.
  }
  throw new Error('Gmail mailbox ownership proof rejected');
}

function googleCacheMaxAge(cacheControl: string): string | undefined {
  return /(?:^|,)\s*max-age=(?<seconds>\d+)/u.exec(cacheControl)?.groups
    ?.seconds;
}

function googleSigningKeyLifetimeMs(response: Response): number {
  const cacheControl = response.headers.get('cache-control') ?? '';
  const maxAge = googleCacheMaxAge(cacheControl);
  const fallbackSeconds = googleSigningKeyFallbackLifetimeMs / 1000;
  const secondsByCacheability = new Map<boolean, number>([
    [true, fallbackSeconds],
    [false, Number(maxAge ?? fallbackSeconds)],
  ]);
  return Math.min(
    (secondsByCacheability.get(/\bno-(?:cache|store)\b/u.test(cacheControl)) ??
      fallbackSeconds) * 1000,
    googleSigningKeyMaximumLifetimeMs,
  );
}

function googleSigningKeyFields(candidate: unknown): Readonly<{
  algorithm: string | null;
  keyId: string;
  keyType: string | null;
  keyUse: string;
}> | null {
  if (!isUnknownRecord(candidate)) {
    return null;
  }
  const algorithm = stringField(candidate, 'alg');
  const keyId = stringField(candidate, 'kid');
  const keyType = stringField(candidate, 'kty');
  const keyUse = stringField(candidate, 'use');
  if (keyId === null) {
    return null;
  }
  return {
    algorithm,
    keyId,
    keyType,
    keyUse: keyUse ?? '',
  };
}

function googleSigningKeyEntry(
  candidate: unknown,
): readonly [string, JsonWebKey] | null {
  const fields = googleSigningKeyFields(candidate);
  if (fields === null) {
    return null;
  }
  const validKey = [
    fields.algorithm === 'RS256',
    fields.keyType === 'RSA',
    ['', 'sig'].includes(fields.keyUse),
  ].every(Boolean);
  if (!validKey) {
    return null;
  }
  // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The accepted JWK fields are validated above.
  return [fields.keyId, candidate as JsonWebKey];
}

function googleSigningKeyCandidates(value: unknown): readonly unknown[] {
  const candidates = isUnknownRecord(value) ? value.keys : undefined;
  if (!Array.isArray(candidates)) {
    // oxlint-disable-next-line unicorn/prefer-type-error -- Preserve the proof rejection error contract.
    throw new Error('Gmail mailbox ownership proof rejected');
  }
  return candidates;
}

function googleSigningKeys(value: unknown): ReadonlyMap<string, JsonWebKey> {
  const entries = googleSigningKeyCandidates(value).flatMap((candidate) => {
    const entry = googleSigningKeyEntry(candidate);
    return entry === null ? [] : [entry];
  });
  const keys = new Map(entries);
  if (keys.size === 0) {
    throw new Error('Gmail mailbox ownership proof rejected');
  }
  return keys;
}

async function fetchGoogleSigningKeys(): Promise<CachedGoogleSigningKeys> {
  const response = await fetch(googleJsonWebKeySetUrl, {
    signal: AbortSignal.timeout(googleSigningKeyFetchTimeoutMs),
  });
  if (!response.ok) {
    throw new Error('Gmail mailbox ownership proof rejected');
  }
  return {
    expiresAt: Date.now() + googleSigningKeyLifetimeMs(response),
    keys: googleSigningKeys(await response.json()),
  };
}

function cachedGoogleSigningKey(keyId: string): JsonWebKey | undefined {
  const cached = cachedGoogleSigningKeys;
  if (cached === null || cached.expiresAt <= Date.now()) {
    return undefined;
  }
  return cached.keys.get(keyId);
}

async function googleSigningKey(keyId: string): Promise<JsonWebKey> {
  const cachedKey = cachedGoogleSigningKey(keyId);
  if (cachedKey !== undefined) {
    return cachedKey;
  }
  const refreshed = await fetchGoogleSigningKeys();
  cachedGoogleSigningKeys = refreshed;
  const key = refreshed.keys.get(keyId);
  if (key === undefined) {
    throw new Error('Gmail mailbox ownership proof rejected');
  }
  return key;
}

async function hasValidGoogleSignature(
  signingInput: string,
  signature: ArrayBuffer,
  keyId: string,
): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    'jwk',
    await googleSigningKey(keyId),
    { hash: 'SHA-256', name: 'RSASSA-PKCS1-v1_5' },
    false,
    ['verify'],
  );
  return crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    key,
    signature,
    new TextEncoder().encode(signingInput),
  );
}

function googleIdentityTokenSegments(
  identityToken: string,
): readonly [string, string, string] {
  const segments = identityToken.split('.');
  if (segments.length !== 3) {
    throw new Error('Gmail mailbox ownership proof rejected');
  }
  return [
    requiredString(segments.at(0)),
    requiredString(segments.at(1)),
    requiredString(segments.at(2)),
  ];
}

function googleIdentityTokenKeyId(headerSegment: string): string {
  const header = decodeJwtRecord(headerSegment);
  const algorithm = stringField(header, 'alg');
  const keyId = stringField(header, 'kid');
  if (algorithm !== 'RS256' || keyId === null) {
    throw new Error('Gmail mailbox ownership proof rejected');
  }
  return keyId;
}

function verifiedGoogleIdentity(
  claimsSegment: string,
  clientId: string,
): VerifiedGoogleIdentity {
  const claims = decodeJwtRecord(claimsSegment);
  const audience = stringField(claims, 'aud');
  const emailAddress = requiredString(stringField(claims, 'email'));
  const expiresAt = Number(claims.exp);
  const issuer = stringField(claims, 'iss');
  const providerAccountIdentifier = requiredString(stringField(claims, 'sub'));
  const emailVerified =
    claims.email_verified === true || claims.email_verified === 'true';
  const validIssuer =
    issuer === 'accounts.google.com' ||
    issuer === 'https://accounts.google.com';
  const validClaims = [
    audience === clientId,
    emailVerified,
    Number.isFinite(expiresAt),
    expiresAt > Math.floor(Date.now() / 1000),
    validIssuer,
  ].every(Boolean);
  if (!validClaims) {
    throw new Error('Gmail mailbox ownership proof rejected');
  }
  return {
    emailAddress,
    providerAccountIdentifier,
  };
}

function gmailOauthClientId(): string {
  // oxlint-disable-next-line node/no-process-env -- The deployment owns the expected Google OAuth audience.
  const clientId = process.env.GMAIL_OAUTH_CLIENT_ID;
  if (clientId === undefined || clientId.length === 0) {
    throw new Error('Gmail mailbox ownership proof is not configured');
  }
  return clientId;
}

async function verifyGoogleIdentityToken(
  identityToken: string,
): Promise<VerifiedGoogleIdentity> {
  const clientId = gmailOauthClientId();
  if (identityToken.length === 0) {
    throw new Error('Gmail mailbox ownership proof required');
  }
  const [headerSegment, claimsSegment, signatureSegment] =
    googleIdentityTokenSegments(identityToken);
  if (
    !(await hasValidGoogleSignature(
      `${headerSegment}.${claimsSegment}`,
      decodeBase64Url(signatureSegment),
      googleIdentityTokenKeyId(headerSegment),
    ))
  ) {
    throw new Error('Gmail mailbox ownership proof rejected');
  }
  return verifiedGoogleIdentity(claimsSegment, clientId);
}

function gmailHistoryIdAtOrAfter(
  candidateHistoryId: string,
  requestedHistoryId: string,
): boolean {
  if (candidateHistoryId === requestedHistoryId) {
    return true;
  }
  try {
    return BigInt(candidateHistoryId) >= BigInt(requestedHistoryId);
  } catch {
    return false;
  }
}

async function legacyGmailRecipient(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  routingDigest: string,
): Promise<ApnsRecipient | null> {
  if (connection.emailAddress === undefined) {
    return null;
  }
  const legacyRoutingDigests = await gmailRoutingDigests(
    connection.emailAddress,
  );
  if (
    !legacyRoutingDigests.some(
      (candidate) => candidate.digest === routingDigest,
    )
  ) {
    return null;
  }
  // oxlint-disable-next-line eslint/no-use-before-define -- Function declarations are hoisted.
  return apnsRecipientForDevice(ctx, {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    routeId: connection._id,
    ownershipVerifiedAt: connection.pushOwnershipVerifiedAt ?? 0,
    pushVerifiedAt: connection.pushVerifiedAt ?? 0,
    trustedDeviceId: connection.trustedDeviceId,
  });
}

// fallow-ignore-next-line complexity
async function gmailRecipients(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  routingDigest: string,
  emailAddress?: string,
): Promise<ApnsRecipient[]> {
  const connections = ctx.db
    .query('mailProviderConnections')
    .withIndex('by_gmailRoutingDigest_and_pushVerifiedAt', (q) =>
      q.eq('gmailRoutingDigest', routingDigest).gt('pushVerifiedAt', undefined),
    );
  const recipients: ApnsRecipient[] = [];

  for await (const connection of connections) {
    // oxlint-disable-next-line eslint/no-use-before-define -- Function declarations are hoisted.
    const recipient = await apnsRecipientForDevice(ctx, {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      routeId: connection._id,
      ownershipVerifiedAt: connection.pushOwnershipVerifiedAt ?? 0,
      pushVerifiedAt: connection.pushVerifiedAt ?? 0,
      trustedDeviceId: connection.trustedDeviceId,
    });
    if (recipient !== null) {
      recipients.push(recipient);
      if (recipients.length === 100) {
        break;
      }
    }
  }

  if (emailAddress !== undefined && recipients.length < 100) {
    const legacyConnections = ctx.db
      .query('mailProviderConnections')
      .withIndex('by_provider_email_gmailDigest_pushVerifiedAt', (q) =>
        q
          .eq('provider', 'gmail')
          .eq('emailAddress', emailAddress)
          .eq('gmailRoutingDigest', undefined)
          .gt('pushVerifiedAt', undefined),
      );
    let inspectedLegacyConnections = 0;
    for await (const connection of legacyConnections) {
      inspectedLegacyConnections += 1;
      if (inspectedLegacyConnections > gmailLegacyRouteFallbackLimit) {
        break;
      }
      const recipient = await legacyGmailRecipient(
        ctx,
        connection,
        routingDigest,
      );
      if (recipient !== null) {
        recipients.push(recipient);
        if (recipients.length >= 100) {
          break;
        }
      }
    }
  }

  return recipients;
}

async function apnsRecipientForDevice(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Request data is immutable input.
  request: Readonly<{
    ownershipVerifiedAt: number;
    routeId: Id<'mailProviderConnections'>;
    pushVerifiedAt: number;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<ApnsRecipient | null> {
  const device = await ctx.db.get(request.trustedDeviceId);
  // oxlint-disable-next-line eslint/no-use-before-define -- Helper narrows the route fields.
  if (!hasActiveApnsRoute(device)) {
    return null;
  }
  const proofTimestamp = Math.min(
    request.ownershipVerifiedAt,
    request.pushVerifiedAt,
  );
  if (proofTimestamp <= (device.gmailPushProofsInvalidatedAt ?? 0)) {
    return null;
  }
  // oxlint-disable-next-line eslint/no-use-before-define -- Helper builds the recipient after route validation.
  return apnsRecipient(device, request.routeId);
}

function apnsRecipient(
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  device: Readonly<
    Doc<'trustedDevices'> & {
      apnsEnvironment: Infer<typeof apnsEnvironmentValidator>;
      apnsToken: string;
    }
  >,
  routeId: Id<'mailProviderConnections'>,
): ApnsRecipient {
  return {
    apnsEnvironment: device.apnsEnvironment,
    apnsToken: device.apnsToken,
    pushCleanupGeneration: device.pushCleanupGeneration ?? 0,
    routeId,
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    trustedDeviceId: device._id,
  };
}

function hasActiveApnsRoute(
  device: Doc<'trustedDevices'> | null, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
): device is Doc<'trustedDevices'> & {
  apnsEnvironment: Infer<typeof apnsEnvironmentValidator>;
  apnsToken: string;
} {
  return (
    device?.apnsEnvironment !== undefined && device.apnsToken !== undefined
  );
}

function isOtherVerifiedGmailRoute(
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  trustedDeviceId: Id<'trustedDevices'>,
): boolean {
  return (
    connection.pushOwnershipVerifiedAt !== undefined &&
    connection.pushVerifiedAt !== undefined &&
    connection.trustedDeviceId !== trustedDeviceId
  );
}

async function isActiveOtherGmailRoute(
  ctx: QueryCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<boolean> {
  if (!isOtherVerifiedGmailRoute(connection, trustedDeviceId)) {
    return false;
  }
  const device = await ctx.db.get(connection.trustedDeviceId);
  return (
    hasActiveApnsRoute(device) &&
    (connection.pushVerifiedAt ?? 0) >
      (device.gmailPushProofsInvalidatedAt ?? 0) &&
    (connection.pushOwnershipVerifiedAt ?? 0) >
      (device.gmailPushProofsInvalidatedAt ?? 0)
  );
}

// The query must distinguish another device's currently routable Gmail proof.
// fallow-ignore-next-line complexity
async function hasOtherActiveGmailRoute(
  ctx: QueryCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
  request: Readonly<{
    emailAddress?: string;
    routingDigests: readonly string[];
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<boolean> {
  let inspectedConnections = 0;
  for (const routingDigest of request.routingDigests) {
    const connections = [
      ctx.db
        .query('mailProviderConnections')
        .withIndex('by_gmailRoutingDigest_and_pushVerifiedAt', (q) =>
          q.eq('gmailRoutingDigest', routingDigest),
        ),
      ctx.db
        .query('mailProviderConnections')
        .withIndex('by_gmailPreviousRoutingDigest_and_pushVerifiedAt', (q) =>
          q.eq('gmailPreviousRoutingDigest', routingDigest),
        ),
    ];
    for (const matchingConnections of connections) {
      for await (const connection of matchingConnections) {
        inspectedConnections += 1;
        if (
          await isActiveOtherGmailRoute(
            ctx,
            connection,
            request.trustedDeviceId,
          )
        ) {
          return true;
        }
        if (inspectedConnections >= gmailActiveRouteInspectionLimit) {
          // Retaining the provider watch is safer than stopping it when the
          // bounded proof search cannot establish that this is the last route.
          return true;
        }
      }
    }
  }
  if (request.emailAddress !== undefined) {
    const legacyConnections = ctx.db
      .query('mailProviderConnections')
      .withIndex('by_provider_email_gmailDigest_pushVerifiedAt', (q) =>
        q
          .eq('provider', 'gmail')
          .eq('emailAddress', request.emailAddress)
          .eq('gmailRoutingDigest', undefined)
          .gt('pushVerifiedAt', undefined),
      );
    for await (const connection of legacyConnections) {
      inspectedConnections += 1;
      if (
        await isActiveOtherGmailRoute(ctx, connection, request.trustedDeviceId)
      ) {
        return true;
      }
      if (inspectedConnections >= gmailActiveRouteInspectionLimit) {
        // Retaining the provider watch is safer than stopping it when the
        // bounded proof search cannot establish that this is the last route.
        return true;
      }
    }
  }
  return false;
}

function gmailConnectionsForDevice(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
) {
  return ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('provider', 'gmail')
        .eq('trustedDeviceId', trustedDeviceId),
    );
}

async function gmailConnection(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
  request: Readonly<{
    opaqueConnectionId: string;
    productAccountId: Id<'productAccounts'>;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<Doc<'mailProviderConnections'> | null> {
  return ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productId_provider_deviceId_connectionId', (q) =>
      q
        .eq('productAccountId', request.productAccountId)
        .eq('provider', 'gmail')
        .eq('trustedDeviceId', request.trustedDeviceId)
        .eq('opaqueConnectionId', request.opaqueConnectionId),
    )
    .unique();
}

async function legacyGmailConnection(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
  request: Readonly<{
    opaqueConnectionId: string;
    productAccountId: Id<'productAccounts'>;
    trustedDeviceId?: Id<'trustedDevices'>;
  }>,
): Promise<Doc<'mailProviderConnections'> | null> {
  const connections =
    request.trustedDeviceId === undefined
      ? ctx.db
          .query('mailProviderConnections')
          .withIndex('by_productAccountId_and_provider', (q) =>
            q
              .eq('productAccountId', request.productAccountId)
              .eq('provider', 'gmail'),
          )
      : gmailConnectionsForDevice(
          ctx,
          request.productAccountId,
          request.trustedDeviceId,
        );
  for await (const candidate of connections) {
    if (
      candidate.opaqueConnectionId === undefined &&
      candidate.providerAccountIdentifier !== undefined
    ) {
      const opaqueConnectionId = await opaqueGmailConnectionId(
        request.productAccountId,
        candidate.providerAccountIdentifier,
      );
      if (opaqueConnectionId === request.opaqueConnectionId) {
        return candidate;
      }
    }
  }
  return null;
}

async function hasRemainingLegacyGmailConnection(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
  request: Readonly<{
    opaqueConnectionId: string;
    productAccountId: Id<'productAccounts'>;
  }>,
): Promise<boolean> {
  const connections = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider', (q) =>
      q
        .eq('productAccountId', request.productAccountId)
        .eq('provider', 'gmail'),
    )
    .take(gmailLegacyRouteFallbackLimit + 1);
  const legacyOpaqueConnectionIds = await Promise.all(
    connections
      .slice(0, gmailLegacyRouteFallbackLimit)
      .flatMap((candidate) =>
        candidate.opaqueConnectionId === undefined &&
        candidate.providerAccountIdentifier !== undefined
          ? [
              opaqueGmailConnectionId(
                request.productAccountId,
                candidate.providerAccountIdentifier,
              ),
            ]
          : [],
      ),
  );
  // Retaining the binding is safer than deleting it when the bounded proof
  // cannot establish that the removed route was the last legacy copy.
  return (
    connections.length > gmailLegacyRouteFallbackLimit ||
    legacyOpaqueConnectionIds.includes(request.opaqueConnectionId)
  );
}

function hasMatchingVerificationSignal(
  signals: ReadonlyArray<Doc<'gmailPushVerificationSignals'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request: Readonly<{ historyId: string; invalidatedAt: number; now: number }>,
): boolean {
  return signals.some(
    (candidate) =>
      candidate.receivedAt > request.invalidatedAt &&
      request.now - candidate.receivedAt <=
        gmailPushVerificationSignalLifetimeMs &&
      gmailHistoryIdAtOrAfter(candidate.historyId, request.historyId),
  );
}

function nextVerifiedHistoryId(
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  historyId: string,
): string {
  if (connection.pushVerifiedHistoryId === undefined) {
    return historyId;
  }
  return gmailHistoryIdAtOrAfter(historyId, connection.pushVerifiedHistoryId)
    ? historyId
    : connection.pushVerifiedHistoryId;
}

function gmailVerificationPatch(
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request: Readonly<{ historyId: string; now: number; verified: boolean }>,
) {
  if (request.verified) {
    return {
      pushVerificationHistoryId: undefined,
      pushVerificationOwnershipVerifiedAt: undefined,
      pushVerificationRequestedAt: undefined,
      pushOwnershipVerifiedAt: request.now,
      pushVerifiedHistoryId: nextVerifiedHistoryId(
        connection,
        request.historyId,
      ),
      pushVerifiedAt: request.now,
    };
  }
  return {
    pushVerificationHistoryId: request.historyId,
    pushVerificationOwnershipVerifiedAt: request.now,
    pushVerificationRequestedAt: request.now,
    pushOwnershipVerifiedAt: connection.pushOwnershipVerifiedAt,
    pushVerifiedHistoryId: connection.pushVerifiedHistoryId,
    pushVerifiedAt: connection.pushVerifiedAt,
  };
}

function gmailPushProofUpdatedAt(
  device: Doc<'trustedDevices'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  now: number,
): number {
  return Math.max(
    now,
    (device.gmailPushProofsInvalidatedAt ?? 0) + 1,
    connection.pushVerifiedAt ?? 0,
  );
}

async function recordGmailVerificationSignal(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  signal: Readonly<{ historyId: string; now: number; routingDigest: string }>,
): Promise<void> {
  const existingSignal = await ctx.db
    .query('gmailPushVerificationSignals')
    .withIndex('by_routingDigest_and_historyId', (q) =>
      q
        .eq('routingDigest', signal.routingDigest)
        .eq('historyId', signal.historyId),
    )
    .unique();
  const signalId =
    existingSignal === null
      ? await ctx.db.insert('gmailPushVerificationSignals', {
          historyId: signal.historyId,
          receivedAt: signal.now,
          routingDigest: signal.routingDigest,
        })
      : existingSignal._id; // oxlint-disable-line eslint/no-underscore-dangle -- Convex document id field
  if (existingSignal !== null) {
    await ctx.db.patch(signalId, { receivedAt: signal.now });
  }
  await ctx.scheduler.runAfter(
    gmailPushVerificationSignalLifetimeMs,
    internal.pushRelay.expireGmailVerificationSignal,
    {
      receivedAt: signal.now,
      signalId,
    },
  );
}

// Each guard validates an independent Gmail proof requirement.
// fallow-ignore-next-line complexity
function pendingVerificationMatches(
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request: Readonly<{ historyId: string; invalidatedAt: number; now: number }>,
): boolean {
  if (connection.pushVerificationHistoryId === undefined) {
    return false;
  }
  if (connection.pushVerificationRequestedAt === undefined) {
    return false;
  }
  if (connection.pushVerificationOwnershipVerifiedAt === undefined) {
    return false;
  }
  return (
    connection.pushVerificationRequestedAt > request.invalidatedAt &&
    connection.pushVerificationOwnershipVerifiedAt > request.invalidatedAt &&
    gmailHistoryIdAtOrAfter(
      request.historyId,
      connection.pushVerificationHistoryId,
    ) &&
    request.now - connection.pushVerificationRequestedAt <=
      gmailPushVerificationSignalLifetimeMs
  );
}

// Pending proofs must be checked independently for every matching Gmail connection.
// fallow-ignore-next-line complexity
async function verifyPendingGmailConnections(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  request: Readonly<{
    cursor?: string | null;
    historyId: string;
    now: number;
    routingDigest: string;
  }>,
): Promise<ApnsRecipient[]> {
  const page = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_gmailRoutingDigest', (q) =>
      q.eq('gmailRoutingDigest', request.routingDigest),
    )
    .order('desc')
    .paginate({
      cursor: request.cursor ?? null,
      numItems: gmailPushVerificationBatchSize,
    });
  const recipients: ApnsRecipient[] = [];
  for (const connection of page.page) {
    const device = await ctx.db.get(connection.trustedDeviceId);
    if (
      device !== null &&
      pendingVerificationMatches(connection, {
        historyId: request.historyId,
        invalidatedAt: device.gmailPushProofsInvalidatedAt ?? 0,
        now: request.now,
      })
    ) {
      const proofUpdatedAt = gmailPushProofUpdatedAt(
        device,
        connection,
        request.now,
      );
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(connection._id, {
        pushVerificationHistoryId: undefined,
        pushVerificationOwnershipVerifiedAt: undefined,
        pushVerificationRequestedAt: undefined,
        pushOwnershipVerifiedAt: proofUpdatedAt,
        pushVerifiedHistoryId: connection.pushVerificationHistoryId,
        pushVerifiedAt: proofUpdatedAt,
      });
      const recipient = await apnsRecipientForDevice(ctx, {
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        routeId: connection._id,
        ownershipVerifiedAt: proofUpdatedAt,
        pushVerifiedAt: proofUpdatedAt,
        trustedDeviceId: connection.trustedDeviceId,
      });
      if (recipient !== null) {
        recipients.push(recipient);
      }
    }
  }
  if (!page.isDone) {
    await ctx.scheduler.runAfter(
      0,
      internal.pushRelay.continuePendingGmailConnectionVerification,
      {
        cursor: page.continueCursor,
        historyId: request.historyId,
        now: request.now,
        routingDigest: request.routingDigest,
      },
    );
  }
  return recipients;
}

async function scheduleGmailWakeups(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  historyId: string,
  recipients: readonly ApnsRecipient[], // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Recipient data is treated as immutable input.
): Promise<void> {
  if (recipients.length === 0) {
    return;
  }
  await ctx.scheduler.runAfter(0, internal.apns.deliverQueuedGmailWakeups, {
    historyId,
    recipients: [...recipients],
  });
}

async function clearGmailPushProofs(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
  request: Readonly<{
    cleanupStartedAt: number;
    cursor?: string | null;
    productAccountId: Id<'productAccounts'>;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<void> {
  const page = await gmailConnectionsForDevice(
    ctx,
    request.productAccountId,
    request.trustedDeviceId,
  ).paginate({
    cursor: request.cursor ?? null,
    numItems: gmailPushProofCleanupBatchSize,
  });
  await Promise.all(
    page.page.map((connection) =>
      // oxlint-disable-next-line eslint/no-use-before-define -- Helper keeps pagination orchestration small.
      clearGmailPushProof(ctx, connection, request.cleanupStartedAt),
    ),
  );
  if (!page.isDone) {
    await ctx.scheduler.runAfter(
      0,
      internal.pushRelay.continueGmailPushProofCleanup,
      {
        cleanupStartedAt: request.cleanupStartedAt,
        cursor: page.continueCursor,
        productAccountId: request.productAccountId,
        trustedDeviceId: request.trustedDeviceId,
      },
    );
  }
}

async function clearGmailPushProof(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context patches proof records.
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  cleanupStartedAt: number,
): Promise<void> {
  // oxlint-disable-next-line eslint/no-use-before-define -- Helper isolates timestamp comparison.
  const clearPendingProof = shouldClearGmailPushProof(
    connection.pushVerificationRequestedAt,
    cleanupStartedAt,
  );
  // oxlint-disable-next-line eslint/no-use-before-define -- Helper isolates timestamp comparison.
  const clearVerifiedProof = shouldClearGmailPushProof(
    connection.pushVerifiedAt,
    cleanupStartedAt,
  );
  if (!clearPendingProof && !clearVerifiedProof) {
    return;
  }
  await ctx.db.patch(
    connection._id, // oxlint-disable-line eslint/no-underscore-dangle -- Convex document id field
    // oxlint-disable-next-line eslint/no-use-before-define -- Helper centralizes the conditional patch.
    gmailPushProofPatch(clearPendingProof, clearVerifiedProof),
  );
}

function shouldClearGmailPushProof(
  proofUpdatedAt: number | undefined,
  cleanupStartedAt: number,
): boolean {
  return proofUpdatedAt === undefined || proofUpdatedAt <= cleanupStartedAt;
}

function gmailPushProofPatch(
  clearPendingProof: boolean,
  clearVerifiedProof: boolean,
) {
  return {
    ...(clearPendingProof
      ? {
          pushVerificationHistoryId: undefined,
          pushVerificationOwnershipVerifiedAt: undefined,
          pushVerificationRequestedAt: undefined,
        }
      : {}),
    ...(clearVerifiedProof
      ? {
          pushOwnershipVerifiedAt: undefined,
          pushVerifiedHistoryId: undefined,
          pushVerifiedAt: undefined,
        }
      : {}),
  };
}

async function devicePushRouteHeartbeat(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<Doc<'devicePushRouteHeartbeats'> | null> {
  return ctx.db
    .query('devicePushRouteHeartbeats')
    .withIndex('by_trustedDeviceId', (q) =>
      q.eq('trustedDeviceId', trustedDeviceId),
    )
    .unique();
}

async function refreshDevicePushRouteHeartbeat(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  trustedDeviceId: Id<'trustedDevices'>,
  refreshedAt: number,
): Promise<void> {
  const heartbeat = await devicePushRouteHeartbeat(ctx, trustedDeviceId);
  if (heartbeat === null) {
    await ctx.db.insert('devicePushRouteHeartbeats', {
      refreshedAt,
      trustedDeviceId,
    });
    return;
  }
  await ctx.db.patch(
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    heartbeat._id,
    { refreshedAt },
  );
}

async function clearDevicePushRoute(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  device: Doc<'trustedDevices'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request?: Readonly<{
    lastSeenAt?: number;
    preservePushCleanupGeneration?: boolean;
  }>,
): Promise<void> {
  const cleanupStartedAt = Date.now();
  // oxlint-disable-next-line eslint/no-use-before-define -- Helper removes the route heartbeat first.
  await deleteDevicePushRouteHeartbeat(ctx, device._id); // oxlint-disable-line eslint/no-underscore-dangle -- Convex document id field
  await ctx.db.patch(
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    device._id,
    // oxlint-disable-next-line eslint/no-use-before-define -- Helper builds the route-clear patch.
    clearedDevicePushRoutePatch(device, request, cleanupStartedAt),
  );
  await ctx.scheduler.runAfter(
    0,
    internal.pushRelay.continueGmailPushProofCleanup,
    {
      cleanupStartedAt,
      productAccountId: device.productAccountId,
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      trustedDeviceId: device._id,
    },
  );
}

function clearedDevicePushRoutePatch(
  device: Doc<'trustedDevices'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request:
    | Readonly<{
        lastSeenAt?: number;
        preservePushCleanupGeneration?: boolean;
      }>
    | undefined,
  cleanupStartedAt: number,
) {
  return {
    apnsEnvironment: undefined,
    apnsToken: undefined,
    apnsTokenRegisteredAt: undefined,
    gmailPushProofsInvalidatedAt: cleanupStartedAt,
    lastSeenAt: request?.lastSeenAt ?? device.lastSeenAt,
    // oxlint-disable-next-line eslint/no-use-before-define -- Helper preserves monotonic cleanup generations.
    pushCleanupGeneration: nextPushCleanupGeneration(device, request),
  };
}

function nextPushCleanupGeneration(
  device: Doc<'trustedDevices'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request: Readonly<{ preservePushCleanupGeneration?: boolean }> | undefined,
): number | undefined {
  if (request?.preservePushCleanupGeneration) {
    return device.pushCleanupGeneration;
  }
  return (device.pushCleanupGeneration ?? 0) + 1;
}

async function deleteDevicePushRouteHeartbeat(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context deletes heartbeat records.
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  const heartbeat = await devicePushRouteHeartbeat(ctx, trustedDeviceId);
  if (heartbeat !== null) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(heartbeat._id);
  }
}

function pushCleanupGenerationForRegistration(
  device: Doc<'trustedDevices'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  args: Readonly<{
    apnsEnvironment: Infer<typeof apnsEnvironmentValidator>;
    apnsToken: string;
  }>,
): number {
  const currentGeneration = device.pushCleanupGeneration ?? 0;
  return device.apnsEnvironment === args.apnsEnvironment &&
    device.apnsToken === args.apnsToken
    ? currentGeneration
    : currentGeneration + 1;
}

async function registeredTrustedDevice(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context reads authentication state.
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<Doc<'trustedDevices'>> {
  await requireAuthenticatedTrustedDevice(ctx, trustedDeviceId);
  const device = await ctx.db.get(trustedDeviceId);
  if (device === null) {
    throw new Error('Trusted device required');
  }
  return device;
}

async function clearReusedApnsToken(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
  request: Readonly<{
    apnsToken: string;
    cleanupStartedAt: number;
    pushCleanupGeneration: number;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<void> {
  const devices = await ctx.db
    .query('trustedDevices')
    .withIndex('by_apnsToken', (q) => q.eq('apnsToken', request.apnsToken))
    .take(devicePushTokenCleanupBatchSize);
  await Promise.all(
    devices
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      .filter((device) => device._id !== request.trustedDeviceId)
      .filter(
        (device) =>
          (device.apnsTokenRegisteredAt ?? 0) <= request.cleanupStartedAt,
      )
      .map((device) => clearDevicePushRoute(ctx, device)),
  );
  if (devices.length === devicePushTokenCleanupBatchSize) {
    await ctx.scheduler.runAfter(
      0,
      internal.pushRelay.continueReusedApnsTokenCleanup,
      {
        apnsToken: request.apnsToken,
        cleanupStartedAt: request.cleanupStartedAt,
        pushCleanupGeneration: request.pushCleanupGeneration,
        trustedDeviceId: request.trustedDeviceId,
      },
    );
  }
}

export const registerDevice = mutation({
  args: {
    apnsEnvironment: apnsEnvironmentValidator,
    apnsToken: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    if (args.apnsToken.length === 0) {
      throw new Error('APNs token required');
    }

    const device = await registeredTrustedDevice(ctx, args.trustedDeviceId);
    const now = Date.now();
    const pushCleanupGeneration = pushCleanupGenerationForRegistration(
      device,
      args,
    );
    await clearReusedApnsToken(ctx, {
      ...args,
      cleanupStartedAt: now,
      pushCleanupGeneration,
    });
    await ctx.db.patch(args.trustedDeviceId, {
      apnsEnvironment: args.apnsEnvironment,
      apnsToken: args.apnsToken,
      apnsTokenRegisteredAt: now,
      lastSeenAt: now,
      pushCleanupGeneration,
    });
    await refreshDevicePushRouteHeartbeat(ctx, args.trustedDeviceId, now);

    return { registered: true };
  },
  returns: devicePushRegistrationResponseValidator,
});

export const unregisterDevice = mutation({
  args: {
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    await requireAuthenticatedTrustedDevice(ctx, args.trustedDeviceId);
    const device = await ctx.db.get(args.trustedDeviceId);
    if (device === null) {
      throw new Error('Trusted device required');
    }
    await clearDevicePushRoute(ctx, device, {
      lastSeenAt: Date.now(),
      preservePushCleanupGeneration: true,
    });

    return { registered: false };
  },
  returns: devicePushRegistrationResponseValidator,
});

export const registerGmailConnection = action({
  args: {
    gmailIdentityToken: v.string(),
    opaqueConnectionId: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args): Promise<GmailOperationalConnectionStatus> => {
    await ctx.runQuery(internal.pushRelay.authenticateGmailWatch, {
      trustedDeviceId: args.trustedDeviceId,
    });
    if (args.opaqueConnectionId.length === 0) {
      throw new Error('Opaque Gmail connection id required');
    }
    const identity = await verifyGoogleIdentityToken(args.gmailIdentityToken);
    const [routing, previousRouting] = await gmailRoutingDigests(
      identity.emailAddress,
    );
    if (routing === undefined) {
      throw new Error('Gmail mailbox ownership proof rejected');
    }
    while (
      await ctx.runMutation(
        internal.pushRelay.clearLegacyGmailSignalsForRegistration,
        {
          emailAddress: identity.emailAddress,
          providerAccountIdentifier: identity.providerAccountIdentifier,
          trustedDeviceId: args.trustedDeviceId,
        },
      )
    ) {
      // Each bounded mutation commits progress before the next batch.
    }
    const status: GmailOperationalConnectionStatus = await ctx.runMutation(
      internal.pushRelay.registerGmailConnectionForIdentity,
      {
        emailAddress: identity.emailAddress,
        gmailPreviousRoutingDigest: previousRouting?.digest,
        gmailRoutingDigest: routing.digest,
        gmailRoutingKeyVersion: routing.keyVersion,
        opaqueConnectionId: args.opaqueConnectionId,
        providerAccountIdentifier: identity.providerAccountIdentifier,
        trustedDeviceId: args.trustedDeviceId,
      },
    );
    return status;
  },
  returns: gmailOperationalConnectionStatusValidator,
});

export const clearLegacyGmailSignalsForRegistration = internalMutation({
  args: {
    emailAddress: v.string(),
    providerAccountIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
    );
    const legacyConnection = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productId_provider_deviceId_providerAccountId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('provider', 'gmail')
          .eq('trustedDeviceId', args.trustedDeviceId)
          .eq('providerAccountIdentifier', args.providerAccountIdentifier),
      )
      .unique();
    if (
      legacyConnection !== null &&
      legacyConnection.emailAddress !== args.emailAddress
    ) {
      throw new Error('Gmail mailbox ownership proof rejected');
    }
    const legacySignals = await ctx.db
      .query('gmailPushVerificationSignals')
      .withIndex('by_emailAddress', (q) =>
        q.eq('emailAddress', args.emailAddress),
      )
      .take(gmailLegacySignalMigrationLimit + 1);
    await Promise.all(
      legacySignals.slice(0, gmailLegacySignalMigrationLimit).map((signal) =>
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        ctx.db.delete(signal._id),
      ),
    );
    return legacySignals.length > gmailLegacySignalMigrationLimit;
  },
  returns: v.boolean(),
});

export const registerGmailConnectionForIdentity = internalMutation({
  args: {
    emailAddress: v.string(),
    gmailPreviousRoutingDigest: v.optional(v.string()),
    gmailRoutingDigest: v.string(),
    gmailRoutingKeyVersion: v.number(),
    opaqueConnectionId: v.string(),
    providerAccountIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  // Registration keeps identity binding and legacy route adoption atomic.
  // fallow-ignore-next-line complexity
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
    );
    const identityBindingDigest = await gmailIdentityBindingDigest(
      account.productAccountId,
      args.providerAccountIdentifier,
    );
    const currentConnection = await gmailConnection(ctx, {
      opaqueConnectionId: args.opaqueConnectionId,
      productAccountId: account.productAccountId,
      trustedDeviceId: args.trustedDeviceId,
    });
    const legacyConnection = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productId_provider_deviceId_providerAccountId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('provider', 'gmail')
          .eq('trustedDeviceId', args.trustedDeviceId)
          .eq('providerAccountIdentifier', args.providerAccountIdentifier),
      )
      .unique();
    if (
      legacyConnection !== null &&
      legacyConnection.emailAddress !== args.emailAddress
    ) {
      throw new Error('Gmail mailbox ownership proof rejected');
    }

    const now = Date.now();
    const identityBinding = await ctx.db
      .query('gmailOpaqueIdentityBindings')
      .withIndex('by_productAccountId_and_opaqueConnectionId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('opaqueConnectionId', args.opaqueConnectionId),
      )
      .unique();
    if (
      identityBinding !== null &&
      identityBinding.identityBindingDigest !== identityBindingDigest
    ) {
      throw new Error('Gmail mailbox ownership proof rejected');
    }
    if (identityBinding === null) {
      await ctx.db.insert('gmailOpaqueIdentityBindings', {
        identityBindingDigest,
        opaqueConnectionId: args.opaqueConnectionId,
        productAccountId: account.productAccountId,
        updatedAt: now,
      });
    }
    let connectedAt = now;
    if (currentConnection !== null) {
      const { _id: connectionId, connectedAt: existingConnectedAt } =
        currentConnection;
      connectedAt = existingConnectedAt;
      await ctx.db.patch(connectionId, {
        emailAddress: undefined,
        gmailPreviousRoutingDigest: args.gmailPreviousRoutingDigest,
        gmailRoutingDigest: args.gmailRoutingDigest,
        gmailRoutingKeyVersion: args.gmailRoutingKeyVersion,
        lastVerifiedAt: now,
        providerAccountIdentifier: undefined,
        updatedAt: now,
      });
      if (
        legacyConnection !== null &&
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        legacyConnection._id !== connectionId
      ) {
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.delete(legacyConnection._id);
      }
    } else if (legacyConnection === null) {
      const deviceConnections = await gmailConnectionsForDevice(
        ctx,
        account.productAccountId,
        args.trustedDeviceId,
      ).take(gmailConnectionLimitPerTrustedDevice + 1);
      if (deviceConnections.length >= gmailConnectionLimitPerTrustedDevice) {
        throw new Error('Gmail connection limit reached');
      }
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        gmailPreviousRoutingDigest: args.gmailPreviousRoutingDigest,
        gmailRoutingDigest: args.gmailRoutingDigest,
        gmailRoutingKeyVersion: args.gmailRoutingKeyVersion,
        lastVerifiedAt: now,
        opaqueConnectionId: args.opaqueConnectionId,
        productAccountId: account.productAccountId,
        provider: 'gmail',
        trustedDeviceId: args.trustedDeviceId,
        updatedAt: now,
      });
    } else {
      const { _id: connectionId, connectedAt: existingConnectedAt } =
        legacyConnection;
      connectedAt = existingConnectedAt;
      await ctx.db.patch(connectionId, {
        emailAddress: undefined,
        gmailPreviousRoutingDigest: args.gmailPreviousRoutingDigest,
        gmailRoutingDigest: args.gmailRoutingDigest,
        gmailRoutingKeyVersion: args.gmailRoutingKeyVersion,
        lastVerifiedAt: now,
        opaqueConnectionId: args.opaqueConnectionId,
        providerAccountIdentifier: undefined,
        updatedAt: now,
      });
    }

    return {
      connectedAt,
      lastVerifiedAt: now,
      opaqueConnectionId: args.opaqueConnectionId,
      trustedDeviceId: args.trustedDeviceId,
      updatedAt: now,
    };
  },
  returns: gmailOperationalConnectionStatusValidator,
});

export const removeGmailConnection = mutation({
  args: {
    opaqueConnectionId: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
    );
    const currentConnection = await gmailConnection(ctx, {
      opaqueConnectionId: args.opaqueConnectionId,
      productAccountId: account.productAccountId,
      trustedDeviceId: args.trustedDeviceId,
    });
    const connection =
      currentConnection ??
      (await legacyGmailConnection(ctx, {
        opaqueConnectionId: args.opaqueConnectionId,
        productAccountId: account.productAccountId,
        trustedDeviceId: args.trustedDeviceId,
      }));
    if (connection !== null) {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(connection._id);
      const remainingOpaqueConnection = await ctx.db
        .query('mailProviderConnections')
        .withIndex(
          'by_productAccountId_and_provider_and_opaqueConnectionId',
          (q) =>
            q
              .eq('productAccountId', account.productAccountId)
              .eq('provider', 'gmail')
              .eq('opaqueConnectionId', args.opaqueConnectionId),
        )
        .first();
      const hasRemainingLegacyConnection =
        await hasRemainingLegacyGmailConnection(ctx, {
          opaqueConnectionId: args.opaqueConnectionId,
          productAccountId: account.productAccountId,
        });
      if (remainingOpaqueConnection === null && !hasRemainingLegacyConnection) {
        const identityBinding = await ctx.db
          .query('gmailOpaqueIdentityBindings')
          .withIndex('by_productAccountId_and_opaqueConnectionId', (q) =>
            q
              .eq('productAccountId', account.productAccountId)
              .eq('opaqueConnectionId', args.opaqueConnectionId),
          )
          .unique();
        if (identityBinding !== null) {
          // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          await ctx.db.delete(identityBinding._id);
        }
      }
    }
    const deviceConnections = await gmailConnectionsForDevice(
      ctx,
      account.productAccountId,
      args.trustedDeviceId,
    ).take(gmailConnectionLimitPerTrustedDevice + 1);
    return {
      hasRemainingGmailConnections: deviceConnections.length > 0,
      removed: connection !== null,
    };
  },
  returns: v.object({
    hasRemainingGmailConnections: v.boolean(),
    removed: v.boolean(),
  }),
});

export const shouldStopGmailWatch = query({
  args: {
    opaqueConnectionId: v.optional(v.string()),
    providerAccountIdentifier: v.optional(v.string()),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
    );
    const opaqueConnectionId =
      args.opaqueConnectionId ??
      (args.providerAccountIdentifier === undefined
        ? null
        : await opaqueGmailConnectionId(
            account.productAccountId,
            args.providerAccountIdentifier,
          ));
    if (opaqueConnectionId === null) {
      throw new Error('Gmail connection required');
    }
    const connection =
      (await gmailConnection(ctx, {
        opaqueConnectionId,
        productAccountId: account.productAccountId,
        trustedDeviceId: args.trustedDeviceId,
      })) ??
      (await legacyGmailConnection(ctx, {
        opaqueConnectionId,
        productAccountId: account.productAccountId,
        trustedDeviceId: args.trustedDeviceId,
      }));
    if (connection === null) {
      throw new Error('Gmail connection required');
    }
    const legacyRoutings =
      connection.gmailRoutingDigest === undefined
        ? await gmailRoutingDigests(connection.emailAddress ?? '')
        : [];
    const routingDigests =
      connection.gmailRoutingDigest === undefined
        ? legacyRoutings.map((routing) => routing.digest)
        : [
            connection.gmailRoutingDigest,
            ...(connection.gmailPreviousRoutingDigest === undefined
              ? []
              : [connection.gmailPreviousRoutingDigest]),
          ];
    return !(await hasOtherActiveGmailRoute(ctx, {
      ...(connection.emailAddress === undefined
        ? {}
        : { emailAddress: connection.emailAddress }),
      routingDigests,
      trustedDeviceId: args.trustedDeviceId,
    }));
  },
  returns: v.boolean(),
});

export const verifyGmailWatch = action({
  args: {
    gmailIdentityToken: v.string(),
    historyId: v.string(),
    opaqueConnectionId: v.optional(v.string()),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    await ctx.runQuery(internal.pushRelay.authenticateGmailWatch, {
      trustedDeviceId: args.trustedDeviceId,
    });
    const identity = await verifyGoogleIdentityToken(args.gmailIdentityToken);
    const routings = await gmailRoutingDigests(identity.emailAddress);
    const [currentRouting] = routings;
    if (currentRouting === undefined) {
      throw new Error('Gmail mailbox ownership proof rejected');
    }
    const result: Infer<typeof gmailPushVerificationResponseValidator> =
      await ctx.runMutation(internal.pushRelay.verifyGmailWatchForIdentity, {
        acceptedRoutingDigests: routings.map((routing) => routing.digest),
        currentRoutingDigest: currentRouting.digest,
        currentRoutingKeyVersion: currentRouting.keyVersion,
        emailAddress: identity.emailAddress,
        historyId: args.historyId,
        opaqueConnectionId: args.opaqueConnectionId,
        providerAccountIdentifier: identity.providerAccountIdentifier,
        trustedDeviceId: args.trustedDeviceId,
      });
    return result;
  },
  returns: gmailPushVerificationResponseValidator,
});

export const authenticateGmailWatch = internalQuery({
  args: {
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    await requireAuthenticatedTrustedDevice(ctx, args.trustedDeviceId);
    return null;
  },
  returns: v.null(),
});

export const verifyGmailWatchForIdentity = internalMutation({
  args: {
    acceptedRoutingDigests: v.array(v.string()),
    currentRoutingDigest: v.string(),
    currentRoutingKeyVersion: v.number(),
    emailAddress: v.string(),
    historyId: v.string(),
    opaqueConnectionId: v.optional(v.string()),
    providerAccountIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  // The mutation has distinct authentication, freshness, and signal-verification guards.
  /* oxlint-disable complexity -- Verification keeps migration and proof updates atomic. */
  // fallow-ignore-next-line complexity
  handler: async (ctx, args) => {
    if (args.historyId.length === 0) {
      throw new Error('Gmail history id required');
    }

    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
    );
    const opaqueConnectionId =
      args.opaqueConnectionId ??
      (await opaqueGmailConnectionId(
        account.productAccountId,
        args.providerAccountIdentifier,
      ));
    const preservesLegacyIdentity = args.opaqueConnectionId === undefined;
    const opaqueConnection = await gmailConnection(ctx, {
      opaqueConnectionId,
      productAccountId: account.productAccountId,
      trustedDeviceId: args.trustedDeviceId,
    });
    const legacyConnection =
      opaqueConnection === null
        ? await ctx.db
            .query('mailProviderConnections')
            .withIndex(
              'by_productId_provider_deviceId_providerAccountId',
              (q) =>
                q
                  .eq('productAccountId', account.productAccountId)
                  .eq('provider', 'gmail')
                  .eq('trustedDeviceId', args.trustedDeviceId)
                  .eq(
                    'providerAccountIdentifier',
                    args.providerAccountIdentifier,
                  ),
            )
            .unique()
        : null;
    if (
      legacyConnection !== null &&
      legacyConnection.emailAddress !== args.emailAddress
    ) {
      throw new Error('Gmail mailbox ownership proof rejected');
    }
    const connection = opaqueConnection ?? legacyConnection;
    if (connection === null) {
      throw new Error('Gmail mailbox ownership proof rejected');
    }
    if (
      opaqueConnection !== null &&
      (connection.gmailRoutingDigest === undefined ||
        !args.acceptedRoutingDigests.includes(connection.gmailRoutingDigest))
    ) {
      throw new Error('Gmail mailbox ownership proof rejected');
    }
    const identityBindingDigest = await gmailIdentityBindingDigest(
      account.productAccountId,
      args.providerAccountIdentifier,
    );
    const identityBinding = await ctx.db
      .query('gmailOpaqueIdentityBindings')
      .withIndex('by_productAccountId_and_opaqueConnectionId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('opaqueConnectionId', opaqueConnectionId),
      )
      .unique();
    if (
      identityBinding !== null &&
      identityBinding.identityBindingDigest !== identityBindingDigest
    ) {
      throw new Error('Gmail mailbox ownership proof rejected');
    }
    const bindingUpdatedAt = Date.now();
    if (identityBinding === null) {
      await ctx.db.insert('gmailOpaqueIdentityBindings', {
        identityBindingDigest,
        opaqueConnectionId,
        productAccountId: account.productAccountId,
        updatedAt: bindingUpdatedAt,
      });
    }
    const device = await ctx.db.get(args.trustedDeviceId);
    if (device === null) {
      throw new Error('Trusted device required');
    }
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    const routeId = connection._id;
    if (
      connection.pushVerifiedHistoryId === args.historyId &&
      (connection.pushVerifiedAt ?? 0) >
        (device.gmailPushProofsInvalidatedAt ?? 0) &&
      (connection.pushOwnershipVerifiedAt ?? 0) >
        (device.gmailPushProofsInvalidatedAt ?? 0)
    ) {
      await ctx.db.patch(routeId, {
        ...(preservesLegacyIdentity ? {} : { emailAddress: undefined }),
        gmailPreviousRoutingDigest: args.acceptedRoutingDigests.at(1),
        gmailRoutingDigest: args.currentRoutingDigest,
        gmailRoutingKeyVersion: args.currentRoutingKeyVersion,
        lastVerifiedAt: Date.now(),
        opaqueConnectionId,
        ...(preservesLegacyIdentity
          ? {}
          : { providerAccountIdentifier: undefined }),
        updatedAt: Date.now(),
      });
      return { routeId, verified: true };
    }

    const signals = await ctx.db
      .query('gmailPushVerificationSignals')
      .withIndex('by_routingDigest', (q) =>
        q.eq('routingDigest', args.currentRoutingDigest),
      )
      .order('desc')
      .take(100);
    const now = gmailPushProofUpdatedAt(device, connection, Date.now());
    const verified = hasMatchingVerificationSignal(signals, {
      historyId: args.historyId,
      invalidatedAt: device.gmailPushProofsInvalidatedAt ?? 0,
      now,
    });
    await ctx.db.patch(
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      connection._id,
      {
        ...(preservesLegacyIdentity ? {} : { emailAddress: undefined }),
        ...gmailVerificationPatch(connection, {
          historyId: args.historyId,
          now,
          verified,
        }),
        gmailPreviousRoutingDigest: args.acceptedRoutingDigests.at(1),
        gmailRoutingDigest: args.currentRoutingDigest,
        gmailRoutingKeyVersion: args.currentRoutingKeyVersion,
        lastVerifiedAt: now,
        opaqueConnectionId,
        ...(preservesLegacyIdentity
          ? {}
          : { providerAccountIdentifier: undefined }),
      },
    );
    return { routeId, verified };
  },
  /* oxlint-enable complexity */
  returns: gmailPushVerificationResponseValidator,
});

export const resolveGmailRecipients = internalQuery({
  args: {
    emailAddress: v.optional(v.string()),
    routingDigest: v.string(),
  },
  handler: async (ctx, args) =>
    gmailRecipients(ctx, args.routingDigest, args.emailAddress),
  returns: v.array(apnsRecipientValidator),
});

export const revalidateGmailRecipients = internalQuery({
  args: { recipients: v.array(apnsRecipientValidator) },
  handler: async (ctx, args) => {
    const candidates = await Promise.all(
      args.recipients.map(async (recipient) => {
        const routeId = ctx.db.normalizeId(
          'mailProviderConnections',
          recipient.routeId,
        );
        if (routeId === null) {
          return null;
        }
        const connection = await ctx.db.get(routeId);
        if (
          connection === null ||
          connection.trustedDeviceId !== recipient.trustedDeviceId
        ) {
          return null;
        }
        const current = await apnsRecipientForDevice(ctx, {
          ownershipVerifiedAt: connection.pushOwnershipVerifiedAt ?? 0,
          pushVerifiedAt: connection.pushVerifiedAt ?? 0,
          routeId,
          trustedDeviceId: connection.trustedDeviceId,
        });
        return current !== null &&
          current.apnsEnvironment === recipient.apnsEnvironment &&
          current.apnsToken === recipient.apnsToken &&
          current.pushCleanupGeneration === recipient.pushCleanupGeneration
          ? current
          : null;
      }),
    );
    return candidates.filter((candidate) => candidate !== null);
  },
  returns: v.array(apnsRecipientValidator),
});

export const enqueueGmailWakeupsFromMetadata = internalAction({
  args: {
    emailAddress: v.string(),
    historyId: v.string(),
  },
  handler: async (ctx, args) => {
    const routings = await gmailRoutingDigests(args.emailAddress);
    const results: Array<{ recipientCount: number }> = await Promise.all(
      routings.map((routing, index) =>
        ctx.runMutation(internal.pushRelay.enqueueGmailWakeups, {
          ...(index === 0 ? { emailAddress: args.emailAddress } : {}),
          historyId: args.historyId,
          routingDigest: routing.digest,
        }),
      ),
    );
    return {
      recipientCount: results.reduce(
        (count, result) => count + result.recipientCount,
        0,
      ),
    };
  },
  returns: v.object({ recipientCount: v.number() }),
});

export const enqueueGmailWakeups = internalMutation({
  args: {
    emailAddress: v.optional(v.string()),
    historyId: v.string(),
    routingDigest: v.string(),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    await recordGmailVerificationSignal(ctx, {
      historyId: args.historyId,
      now,
      routingDigest: args.routingDigest,
    });
    await verifyPendingGmailConnections(ctx, {
      historyId: args.historyId,
      now,
      routingDigest: args.routingDigest,
    });

    const recipients = await gmailRecipients(
      ctx,
      args.routingDigest,
      args.emailAddress,
    );
    await scheduleGmailWakeups(ctx, args.historyId, recipients);

    return { recipientCount: recipients.length };
  },
  returns: v.object({ recipientCount: v.number() }),
});

export const continuePendingGmailConnectionVerification = internalMutation({
  args: {
    cursor: v.union(v.string(), v.null()),
    historyId: v.string(),
    now: v.number(),
    routingDigest: v.string(),
  },
  handler: async (ctx, args) => {
    const recipients = await verifyPendingGmailConnections(ctx, args);
    await scheduleGmailWakeups(ctx, args.historyId, recipients);
    return { recipientCount: recipients.length };
  },
  returns: v.object({ recipientCount: v.number() }),
});

export const expireGmailVerificationSignal = internalMutation({
  args: {
    receivedAt: v.number(),
    signalId: v.id('gmailPushVerificationSignals'),
  },
  handler: async (ctx, args) => {
    const signal = await ctx.db.get(args.signalId);
    if (signal?.receivedAt === args.receivedAt) {
      await ctx.db.delete(args.signalId);
    }
    return null;
  },
  returns: v.null(),
});

export const continueGmailPushProofCleanup = internalMutation({
  args: {
    cleanupStartedAt: v.number(),
    cursor: v.optional(v.string()),
    productAccountId: v.id('productAccounts'),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    await clearGmailPushProofs(ctx, args);
    return null;
  },
  returns: v.null(),
});

export const continueReusedApnsTokenCleanup = internalMutation({
  args: {
    apnsToken: v.string(),
    cleanupStartedAt: v.number(),
    pushCleanupGeneration: v.number(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const tokenOwners = await ctx.db
      .query('trustedDevices')
      .withIndex('by_apnsToken_and_apnsTokenRegisteredAt', (q) =>
        q
          .eq('apnsToken', args.apnsToken)
          .gte('apnsTokenRegisteredAt', args.cleanupStartedAt),
      )
      .order('desc')
      .take(2);
    if (
      tokenOwners.some(
        (owner) =>
          // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          owner._id !== args.trustedDeviceId &&
          owner.pushCleanupGeneration !== undefined &&
          (owner.apnsTokenRegisteredAt ?? 0) >= args.cleanupStartedAt,
      )
    ) {
      return null;
    }
    await clearReusedApnsToken(ctx, args);
    return null;
  },
  returns: v.null(),
});

export const reconcileStaleDevicePushRoutes = internalMutation({
  args: {
    cursor: v.optional(v.string()),
    staleBefore: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const staleBefore =
      args.staleBefore ?? Date.now() - devicePushRouteInactivityLifetimeMs;
    const page = await ctx.db
      .query('trustedDevices')
      .withIndex('by_apnsToken', (q) => q.gt('apnsToken', ''))
      .paginate({
        cursor: args.cursor ?? null,
        numItems: devicePushRouteReconciliationBatchSize,
      });
    const heartbeats = await Promise.all(
      page.page.map((device) =>
        devicePushRouteHeartbeat(
          ctx,
          // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          device._id,
        ),
      ),
    );
    const staleDeviceIds = new Set(
      page.page
        .filter(
          (device, index) =>
            (heartbeats[index]?.refreshedAt ?? device.lastSeenAt) < staleBefore,
        )
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        .map((device) => device._id),
    );
    await Promise.all(
      page.page.map(async (device, index) => {
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        if (staleDeviceIds.has(device._id)) {
          await clearDevicePushRoute(ctx, device);
          return;
        }
        if (heartbeats[index] === null) {
          await refreshDevicePushRouteHeartbeat(
            ctx,
            // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
            device._id,
            device.lastSeenAt,
          );
        }
      }),
    );
    if (!page.isDone) {
      await ctx.scheduler.runAfter(
        0,
        internal.pushRelay.reconcileStaleDevicePushRoutes,
        { cursor: page.continueCursor, staleBefore },
      );
    }

    return { clearedRouteCount: staleDeviceIds.size };
  },
  returns: v.object({ clearedRouteCount: v.number() }),
});

export const clearStaleDevice = internalMutation({
  args: {
    apnsToken: v.string(),
    pushCleanupGeneration: v.number(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const device = await ctx.db.get(args.trustedDeviceId);
    // oxlint-disable-next-line eslint/no-use-before-define -- Helper validates the current route identity.
    if (isCurrentPushRoute(device, args)) {
      await clearDevicePushRoute(ctx, device);
    }
    return null;
  },
  returns: v.null(),
});

const microsoftGraphRouteResponseValidator = v.object({
  routeId: v.string(),
});

async function microsoftGraphWakeupState(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  routeId: Id<'mailProviderConnections'>,
): Promise<Doc<'microsoftGraphWakeupStates'> | null> {
  return ctx.db
    .query('microsoftGraphWakeupStates')
    .withIndex('by_routeId', (q) => q.eq('routeId', routeId))
    .unique();
}

async function deleteMicrosoftGraphWakeupState(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  routeId: Id<'mailProviderConnections'>,
): Promise<void> {
  const state = await microsoftGraphWakeupState(ctx, routeId);
  if (state !== null) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(state._id);
  }
}

type PrepareMicrosoftGraphRouteArgs = Readonly<{
  clientStateDigest: string;
  opaqueConnectionId: string;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

type ConfirmMicrosoftGraphRouteArgs = Readonly<{
  clientStateDigest?: string;
  expiresAt: number;
  routeId: Id<'mailProviderConnections'>;
  subscriptionId: string;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

type MicrosoftGraphWakeupArgs = Readonly<{
  clientStateDigest: string;
  routeId: string;
  subscriptionId: string;
}>;

function requireMicrosoftGraphRouteIdentifiers(
  args: PrepareMicrosoftGraphRouteArgs, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
): void {
  if (
    args.clientStateDigest.length === 0 ||
    args.opaqueConnectionId.length === 0
  ) {
    throw new Error('Microsoft Graph route identifiers required');
  }
}

async function existingMicrosoftGraphRoute(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  args: PrepareMicrosoftGraphRouteArgs, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
): Promise<Doc<'mailProviderConnections'> | null> {
  return ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productId_provider_deviceId_connectionId', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('provider', 'microsoft-graph')
        .eq('trustedDeviceId', args.trustedDeviceId)
        .eq('opaqueConnectionId', args.opaqueConnectionId),
    )
    .unique();
}

type MicrosoftGraphRouteContext = Readonly<{
  existing: Doc<'mailProviderConnections'> | null;
  productAccountId: Id<'productAccounts'>;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

async function requireMicrosoftGraphConnectionCapacity(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  routeContext: MicrosoftGraphRouteContext, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents and identifiers are branded values.
): Promise<void> {
  if (routeContext.existing !== null) {
    return;
  }
  const deviceConnections = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
      q
        .eq('productAccountId', routeContext.productAccountId)
        .eq('provider', 'microsoft-graph')
        .eq('trustedDeviceId', routeContext.trustedDeviceId),
    )
    .take(microsoftGraphConnectionLimitPerTrustedDevice + 1);
  if (
    deviceConnections.length >= microsoftGraphConnectionLimitPerTrustedDevice
  ) {
    throw new Error('Microsoft Graph connection limit reached');
  }
}

type SaveMicrosoftGraphRouteOptions = Readonly<{
  existing: Doc<'mailProviderConnections'> | null;
  now: number;
  productAccountId: Id<'productAccounts'>;
}>;

function hasActiveMicrosoftGraphSubscription(
  route: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is inspected but not mutated.
  now: number,
): boolean {
  return (
    route.microsoftSubscriptionId !== undefined &&
    (route.microsoftSubscriptionExpiresAt ?? 0) > now
  );
}

async function saveMicrosoftGraphRoute(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  args: PrepareMicrosoftGraphRouteArgs, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
  options: SaveMicrosoftGraphRouteOptions, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents and identifiers are branded values.
): Promise<Id<'mailProviderConnections'>> {
  if (options.existing === null) {
    return ctx.db.insert('mailProviderConnections', {
      connectedAt: options.now,
      lastVerifiedAt: options.now,
      microsoftClientStateDigest: args.clientStateDigest,
      opaqueConnectionId: args.opaqueConnectionId,
      productAccountId: options.productAccountId,
      provider: 'microsoft-graph',
      trustedDeviceId: args.trustedDeviceId,
      updatedAt: options.now,
    });
  }
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  const routeId = options.existing._id;
  if (hasActiveMicrosoftGraphSubscription(options.existing, options.now)) {
    await ctx.db.patch(routeId, {
      lastVerifiedAt: options.now,
      microsoftPendingClientStateDigest: args.clientStateDigest,
      updatedAt: options.now,
    });
    return routeId;
  }
  await deleteMicrosoftGraphWakeupState(ctx, routeId);
  await ctx.db.patch(routeId, {
    lastVerifiedAt: options.now,
    microsoftClientStateDigest: args.clientStateDigest,
    microsoftPendingClientStateDigest: undefined,
    microsoftSubscriptionExpiresAt: undefined,
    microsoftSubscriptionId: undefined,
    updatedAt: options.now,
  });
  return routeId;
}

async function prepareMicrosoftGraphRouteForDevice(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  args: PrepareMicrosoftGraphRouteArgs, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
): Promise<{ routeId: Id<'mailProviderConnections'> }> {
  const account = await requireAuthenticatedTrustedDevice(
    ctx,
    args.trustedDeviceId,
  );
  requireMicrosoftGraphRouteIdentifiers(args);
  const existing = await existingMicrosoftGraphRoute(
    ctx,
    account.productAccountId,
    args,
  );
  await requireMicrosoftGraphConnectionCapacity(ctx, {
    existing,
    productAccountId: account.productAccountId,
    trustedDeviceId: args.trustedDeviceId,
  });
  const now = Date.now();
  const routeId = await saveMicrosoftGraphRoute(ctx, args, {
    existing,
    now,
    productAccountId: account.productAccountId,
  });
  await refreshDevicePushRouteHeartbeat(ctx, args.trustedDeviceId, now);
  return { routeId };
}

export const prepareMicrosoftGraphRoute = mutation({
  args: {
    clientStateDigest: v.string(),
    opaqueConnectionId: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: prepareMicrosoftGraphRouteForDevice,
  returns: microsoftGraphRouteResponseValidator,
});

function requireMicrosoftGraphRoute(
  route: Doc<'mailProviderConnections'> | null, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is inspected but not mutated.
): asserts route is Doc<'mailProviderConnections'> {
  if (route === null || route.provider !== 'microsoft-graph') {
    throw new Error('Microsoft Graph route rejected');
  }
}

function requireMicrosoftGraphRouteOwnership(
  route: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is inspected but not mutated.
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): void {
  if (
    route.productAccountId !== productAccountId ||
    route.trustedDeviceId !== trustedDeviceId
  ) {
    throw new Error('Microsoft Graph route rejected');
  }
}

function hasMatchingMicrosoftGraphConfirmation(
  route: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is inspected but not mutated.
  args: ConfirmMicrosoftGraphRouteArgs, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
): boolean {
  if (route.microsoftClientStateDigest === undefined) {
    return false;
  }
  return args.clientStateDigest === undefined
    ? route.microsoftSubscriptionId === args.subscriptionId
    : route.microsoftClientStateDigest === args.clientStateDigest ||
        route.microsoftPendingClientStateDigest === args.clientStateDigest;
}

function requireValidMicrosoftGraphConfirmation(
  route: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is inspected but not mutated.
  args: ConfirmMicrosoftGraphRouteArgs, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
): void {
  if (args.subscriptionId.length === 0 || args.expiresAt <= Date.now()) {
    throw new Error('Microsoft Graph route rejected');
  }
  if (!hasMatchingMicrosoftGraphConfirmation(route, args)) {
    throw new Error('Microsoft Graph route rejected');
  }
}

async function confirmMicrosoftGraphRouteForDevice(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  args: ConfirmMicrosoftGraphRouteArgs, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
): Promise<{ routeId: Id<'mailProviderConnections'> }> {
  const account = await requireAuthenticatedTrustedDevice(
    ctx,
    args.trustedDeviceId,
  );
  const route = await ctx.db.get(args.routeId);
  requireMicrosoftGraphRoute(route);
  requireMicrosoftGraphRouteOwnership(
    route,
    account.productAccountId,
    args.trustedDeviceId,
  );
  requireValidMicrosoftGraphConfirmation(route, args);
  const now = Date.now();
  const confirmsPendingReplacement =
    args.clientStateDigest !== undefined &&
    route.microsoftPendingClientStateDigest === args.clientStateDigest;
  let confirmedClientStateDigest = route.microsoftClientStateDigest;
  let pendingClientStateDigest = route.microsoftPendingClientStateDigest;
  if (confirmsPendingReplacement) {
    await deleteMicrosoftGraphWakeupState(ctx, args.routeId);
    confirmedClientStateDigest = args.clientStateDigest;
    pendingClientStateDigest = undefined;
  }
  await ctx.db.patch(args.routeId, {
    lastVerifiedAt: now,
    microsoftClientStateDigest: confirmedClientStateDigest,
    microsoftPendingClientStateDigest: pendingClientStateDigest,
    microsoftSubscriptionExpiresAt: args.expiresAt,
    microsoftSubscriptionId: args.subscriptionId,
    updatedAt: now,
  });
  await refreshDevicePushRouteHeartbeat(ctx, args.trustedDeviceId, now);
  return { routeId: args.routeId };
}

export const confirmMicrosoftGraphRoute = mutation({
  args: {
    clientStateDigest: v.optional(v.string()),
    expiresAt: v.number(),
    routeId: v.id('mailProviderConnections'),
    subscriptionId: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: confirmMicrosoftGraphRouteForDevice,
  returns: microsoftGraphRouteResponseValidator,
});

export const removeMicrosoftGraphRoute = mutation({
  args: {
    opaqueConnectionId: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
    );
    const route = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productId_provider_deviceId_connectionId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('provider', 'microsoft-graph')
          .eq('trustedDeviceId', args.trustedDeviceId)
          .eq('opaqueConnectionId', args.opaqueConnectionId),
      )
      .unique();
    if (route !== null) {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await deleteMicrosoftGraphWakeupState(ctx, route._id);
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(route._id);
    }
    return { removed: route !== null };
  },
  returns: v.object({ removed: v.boolean() }),
});

function isActiveMicrosoftGraphRoute(
  route: Doc<'mailProviderConnections'> | null, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is inspected but not mutated.
  now: number,
): route is Doc<'mailProviderConnections'> {
  return (
    route !== null &&
    route.provider === 'microsoft-graph' &&
    (route.microsoftSubscriptionExpiresAt ?? 0) > now
  );
}

function matchesMicrosoftGraphSubscription(
  route: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is inspected but not mutated.
  args: MicrosoftGraphWakeupArgs,
): boolean {
  return (
    route.microsoftClientStateDigest === args.clientStateDigest &&
    route.microsoftSubscriptionId === args.subscriptionId
  );
}

async function acceptedMicrosoftGraphWakeupRoute(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  args: MicrosoftGraphWakeupArgs,
  now: number,
): Promise<Id<'mailProviderConnections'> | null> {
  const routeId = ctx.db.normalizeId('mailProviderConnections', args.routeId);
  if (routeId === null) {
    return null;
  }
  const route = await ctx.db.get(routeId);
  if (!isActiveMicrosoftGraphRoute(route, now)) {
    return null;
  }
  if (!matchesMicrosoftGraphSubscription(route, args)) {
    return null;
  }
  return routeId;
}

async function enqueueMicrosoftGraphWakeupForRoute(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  args: MicrosoftGraphWakeupArgs,
): Promise<{ accepted: boolean }> {
  const now = Date.now();
  const routeId = await acceptedMicrosoftGraphWakeupRoute(ctx, args, now);
  if (routeId === null) {
    return { accepted: false };
  }
  const existing = await microsoftGraphWakeupState(ctx, routeId);
  if (existing !== null) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.patch(existing._id, { attemptCount: 0, pendingAt: now });
    return { accepted: true };
  }
  await ctx.db.insert('microsoftGraphWakeupStates', {
    attemptCount: 0,
    pendingAt: now,
    routeId,
    scheduledAt: now,
  });
  await ctx.scheduler.runAfter(
    1000,
    internal.apns.deliverMicrosoftGraphWakeup,
    { routeId, scheduledAt: now },
  );
  return { accepted: true };
}

export const enqueueMicrosoftGraphWakeup = internalMutation({
  args: {
    clientStateDigest: v.string(),
    routeId: v.string(),
    subscriptionId: v.string(),
  },
  handler: enqueueMicrosoftGraphWakeupForRoute,
  returns: v.object({ accepted: v.boolean() }),
});

type MicrosoftGraphWakeupScheduleArgs = Readonly<{
  routeId: Id<'mailProviderConnections'>;
  scheduledAt: number;
}>;

function isMatchingMicrosoftGraphWakeupState(
  state: Doc<'microsoftGraphWakeupStates'> | null, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is inspected but not mutated.
  scheduledAt: number,
): state is Doc<'microsoftGraphWakeupStates'> {
  return state !== null && state.scheduledAt === scheduledAt;
}

async function claimMicrosoftGraphWakeupForRoute(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  args: MicrosoftGraphWakeupScheduleArgs, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
): Promise<ApnsRecipient | null> {
  const route = await ctx.db.get(args.routeId);
  const state = await microsoftGraphWakeupState(ctx, args.routeId);
  if (!isMatchingMicrosoftGraphWakeupState(state, args.scheduledAt)) {
    return null;
  }
  if (!isActiveMicrosoftGraphRoute(route, Date.now())) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(state._id);
    return null;
  }
  const device = await ctx.db.get(route.trustedDeviceId);
  if (!hasActiveApnsRoute(device)) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(state._id);
    return null;
  }
  await ctx.scheduler.runAfter(
    microsoftGraphWakeupClaimLeaseMs,
    internal.apns.deliverMicrosoftGraphWakeup,
    args,
  );
  return apnsRecipient(device, args.routeId);
}

export const claimMicrosoftGraphWakeup = internalMutation({
  args: {
    routeId: v.id('mailProviderConnections'),
    scheduledAt: v.number(),
  },
  handler: claimMicrosoftGraphWakeupForRoute,
  returns: v.union(apnsRecipientValidator, v.null()),
});

type CompleteMicrosoftGraphWakeupArgs = MicrosoftGraphWakeupScheduleArgs &
  Readonly<{ delivered: boolean; terminalFailure?: boolean }>;

async function microsoftGraphRouteDevice(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  route: Doc<'mailProviderConnections'> | null, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is inspected but not mutated.
): Promise<Doc<'trustedDevices'> | null> {
  if (route?.provider !== 'microsoft-graph') {
    return null;
  }
  return ctx.db.get(route.trustedDeviceId);
}

type MicrosoftGraphWakeupCompletionContext = Readonly<{
  device: Doc<'trustedDevices'> | null;
  route: Doc<'mailProviderConnections'> | null;
  state: Doc<'microsoftGraphWakeupStates'>;
}>;

function microsoftGraphWakeupAttemptCount(
  state: Doc<'microsoftGraphWakeupStates'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is inspected but not mutated.
): number {
  return state.attemptCount ?? 0;
}

function microsoftGraphWakeupPendingAt(
  state: Doc<'microsoftGraphWakeupStates'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is inspected but not mutated.
): number {
  return state.pendingAt ?? state.scheduledAt;
}

function hasUsableMicrosoftGraphWakeupRoute(
  context: MicrosoftGraphWakeupCompletionContext, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are inspected but not mutated.
): boolean {
  if (!isActiveMicrosoftGraphRoute(context.route, Date.now())) {
    return false;
  }
  return hasActiveApnsRoute(context.device);
}

function shouldDiscardMicrosoftGraphWakeup(
  context: MicrosoftGraphWakeupCompletionContext, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are inspected but not mutated.
  args: CompleteMicrosoftGraphWakeupArgs, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
): boolean {
  if (args.terminalFailure === true) {
    return true;
  }
  if (!hasUsableMicrosoftGraphWakeupRoute(context)) {
    return true;
  }
  if (args.delivered) {
    return microsoftGraphWakeupPendingAt(context.state) <= args.scheduledAt;
  }
  return (
    microsoftGraphWakeupAttemptCount(context.state) + 1 >=
    microsoftGraphWakeupMaximumAttempts
  );
}

function microsoftGraphWakeupRetryDelay(attemptCount: number): number {
  return Math.min(
    microsoftGraphWakeupRetryBaseDelayMs * 2 ** Math.max(0, attemptCount - 1),
    microsoftGraphWakeupMaximumRetryDelayMs,
  );
}

function nextMicrosoftGraphWakeupAttemptCount(
  state: Doc<'microsoftGraphWakeupStates'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is inspected but not mutated.
  delivered: boolean,
): number {
  return delivered ? 0 : microsoftGraphWakeupAttemptCount(state) + 1;
}

function nextMicrosoftGraphWakeupDelay(
  delivered: boolean,
  attemptCount: number,
): number {
  return delivered ? 0 : microsoftGraphWakeupRetryDelay(attemptCount);
}

async function scheduleMicrosoftGraphWakeupRetry(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  state: Doc<'microsoftGraphWakeupStates'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex document is mutated through the database.
  args: CompleteMicrosoftGraphWakeupArgs, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
): Promise<void> {
  const attemptCount = nextMicrosoftGraphWakeupAttemptCount(
    state,
    args.delivered,
  );
  const delay = nextMicrosoftGraphWakeupDelay(args.delivered, attemptCount);
  const retryScheduledAt = Math.max(Date.now(), args.scheduledAt + delay);
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  await ctx.db.patch(state._id, {
    attemptCount,
    scheduledAt: retryScheduledAt,
  });
  await ctx.scheduler.runAfter(
    delay,
    internal.apns.deliverMicrosoftGraphWakeup,
    { routeId: args.routeId, scheduledAt: retryScheduledAt },
  );
}

async function completeMicrosoftGraphWakeupForRoute(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  args: CompleteMicrosoftGraphWakeupArgs, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
): Promise<null> {
  const state = await microsoftGraphWakeupState(ctx, args.routeId);
  if (state?.scheduledAt !== args.scheduledAt) {
    return null;
  }
  const route = await ctx.db.get(args.routeId);
  const device = await microsoftGraphRouteDevice(ctx, route);
  if (shouldDiscardMicrosoftGraphWakeup({ device, route, state }, args)) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(state._id);
    return null;
  }
  await scheduleMicrosoftGraphWakeupRetry(ctx, state, args);
  return null;
}

export const completeMicrosoftGraphWakeup = internalMutation({
  args: {
    delivered: v.boolean(),
    routeId: v.id('mailProviderConnections'),
    scheduledAt: v.number(),
    terminalFailure: v.optional(v.boolean()),
  },
  handler: completeMicrosoftGraphWakeupForRoute,
  returns: v.null(),
});

function isCurrentPushRoute(
  device: Doc<'trustedDevices'> | null, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request: Readonly<{
    apnsToken: string;
    pushCleanupGeneration: number;
  }>,
): device is Doc<'trustedDevices'> {
  return (
    device?.apnsToken === request.apnsToken &&
    (device.pushCleanupGeneration ?? 0) === request.pushCleanupGeneration
  );
}
