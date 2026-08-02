'use node';

import { createPrivateKey, sign } from 'node:crypto';

import { productAccountDeletionResponseValidator } from '@private-email/contracts';
import { v } from 'convex/values';

import type { Id } from './_generated/dataModel.js';

import { internal } from './_generated/api.js';
import { action } from './_generated/server.js';

const appleAudience = 'https://appleid.apple.com';
const appleRevokeUrl = `${appleAudience}/auth/revoke`;
const appleTokenUrl = `${appleAudience}/auth/token`;

type RevocationMaterial =
  | Readonly<{ kind: 'authorization-code'; value: string }>
  | Readonly<{ kind: 'refresh-token'; value: string }>;

function requiredEnvironmentValue(name: string): string {
  // oxlint-disable-next-line node/no-process-env -- Convex actions read deployment env at runtime.
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing ${name} configuration`);
  }
  return value;
}

function encodeJson(value: Readonly<Record<string, string | number>>): string {
  return Buffer.from(JSON.stringify(value)).toString('base64url');
}

function appleClientSecret(): string {
  const now = Math.floor(Date.now() / 1000);
  const header = encodeJson({
    alg: 'ES256',
    kid: requiredEnvironmentValue('APPLE_SIGN_IN_KEY_ID'),
  });
  const payload = encodeJson({
    aud: appleAudience,
    exp: now + 300,
    iat: now,
    iss: requiredEnvironmentValue('APPLE_TEAM_ID'),
    sub: requiredEnvironmentValue('APPLE_BUNDLE_ID'),
  });
  const unsignedToken = `${header}.${payload}`;
  const signature = sign('sha256', Buffer.from(unsignedToken), {
    dsaEncoding: 'ieee-p1363',
    key: createPrivateKey(
      requiredEnvironmentValue('APPLE_SIGN_IN_PRIVATE_KEY'),
    ),
  }).toString('base64url');
  return `${unsignedToken}.${signature}`;
}

function formBody(values: Readonly<Record<string, string>>): URLSearchParams {
  return new URLSearchParams(values);
}

function retryableAppleError(): Error {
  return new Error('Apple authorization revocation is temporarily unavailable');
}

async function postToApple(
  url: string,
  values: Readonly<Record<string, string>>,
): Promise<Response> {
  try {
    return await fetch(url, {
      body: formBody(values),
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      method: 'POST',
    });
  } catch {
    throw retryableAppleError();
  }
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === 'object' && value !== null;
}

function identityTokenSubject(identityToken: string): string | undefined {
  const [, payload] = identityToken.split('.');
  if (!payload) {
    return undefined;
  }
  try {
    const decoded: unknown = JSON.parse(
      Buffer.from(payload, 'base64url').toString('utf8'),
    );
    return isRecord(decoded) && typeof decoded.sub === 'string'
      ? decoded.sub
      : undefined;
  } catch {
    return undefined;
  }
}

async function exchangeAuthorizationCode(
  authorizationCode: string,
  expectedSubject: string,
): Promise<string> {
  const response = await postToApple(appleTokenUrl, {
    client_id: requiredEnvironmentValue('APPLE_BUNDLE_ID'),
    client_secret: appleClientSecret(),
    code: authorizationCode,
    grant_type: 'authorization_code',
  });
  if (response.status >= 500) {
    throw retryableAppleError();
  }
  if (!response.ok) {
    throw new Error('Apple authorization exchange failed');
  }
  const body: unknown = await response.json();
  if (
    !isRecord(body) ||
    typeof body.refresh_token !== 'string' ||
    typeof body.id_token !== 'string'
  ) {
    throw new Error('Apple authorization exchange failed');
  }
  if (identityTokenSubject(body.id_token) !== expectedSubject) {
    throw new Error('Recent authentication must match the Product Account');
  }
  return body.refresh_token;
}

async function revokeAppleToken(refreshToken: string): Promise<void> {
  const response = await postToApple(appleRevokeUrl, {
    client_id: requiredEnvironmentValue('APPLE_BUNDLE_ID'),
    client_secret: appleClientSecret(),
    token: refreshToken,
    token_type_hint: 'refresh_token',
  });
  if (response.status >= 500) {
    throw retryableAppleError();
  }
  if (!response.ok) {
    throw new Error('Apple authorization revocation failed');
  }
}

export const deleteProductAccount = action({
  args: {
    authorizationCode: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error('Authentication required');
    }
    const prepared: Readonly<
      | { state: 'already-deleted' }
      | {
          phase: 'deleting-data' | 'revocation-pending';
          requestId: Id<'productAccountDeletionRequests'>;
          revocationMaterial?: RevocationMaterial;
          state: 'pending';
        }
    > = await ctx.runMutation(
      internal.productAccountDeletionData.prepareDeletion,
      args,
    );
    if (prepared.state === 'already-deleted') {
      return { deleted: true };
    }

    if (prepared.phase === 'revocation-pending') {
      try {
        let refreshToken: string | undefined = undefined;
        if (prepared.revocationMaterial?.kind === 'refresh-token') {
          refreshToken = prepared.revocationMaterial.value;
        } else if (prepared.revocationMaterial?.kind === 'authorization-code') {
          refreshToken = await exchangeAuthorizationCode(
            prepared.revocationMaterial.value,
            identity.subject,
          );
        }
        if (refreshToken === undefined) {
          throw new Error(
            'Recent Sign in with Apple authorization is required',
          );
        }
        if (prepared.revocationMaterial?.kind === 'authorization-code') {
          await ctx.runMutation(
            internal.productAccountDeletionData.storeRefreshToken,
            { refreshToken, requestId: prepared.requestId },
          );
        }
        await revokeAppleToken(refreshToken);
      } catch (error) {
        if (
          error instanceof Error &&
          error.message ===
            'Apple authorization revocation is temporarily unavailable'
        ) {
          throw error;
        }
        await ctx.runMutation(
          internal.productAccountDeletionData.abortDeletion,
          {
            requestId: prepared.requestId,
          },
        );
        throw error;
      }
      await ctx.runMutation(
        internal.productAccountDeletionData.markRevocationComplete,
        { requestId: prepared.requestId },
      );
    }

    let complete = false;
    while (!complete) {
      const { complete: batchComplete }: Readonly<{ complete: boolean }> =
        await ctx.runMutation(
          internal.productAccountDeletionData.deleteNextBatch,
          { requestId: prepared.requestId },
        );
      complete = batchComplete;
    }
    return { deleted: true };
  },
  returns: productAccountDeletionResponseValidator,
});
