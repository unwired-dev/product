/// <reference types="vite/client" />

import { convexTest } from 'convex-test';

import type { ActionCtx } from '../convex/_generated/server.js';

import http from '../convex/http.js';
import schema from '../convex/schema.js';

const modules = import.meta.glob('../convex/**/*.ts');

describe('bearer-authenticated HTTP routes', () => {
  it.each([
    '/trusted-devices/revoke',
    '/sign-in-links/request',
    '/sign-in-links/complete',
    '/product-sync/recovery-material',
  ])('%s returns 401 when Convex identity lookup rejects', async (path) => {
    expect.hasAssertions();
    const registeredHandler = http.lookup(path, 'POST')?.[0];
    // Convex uses this entry point in convex-test but strips it from published types.
    // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- Restore Convex's internal HTTP test entry point.
    const handler = registeredHandler as NonNullable<
      typeof registeredHandler
    > & {
      _handler: (ctx: ActionCtx, request: Request) => Promise<Response>;
    };
    const claims = Buffer.from(
      JSON.stringify({
        iat: Math.floor(Date.now() / 1000),
        iss: 'https://accounts.google.com',
        sub: 'http-auth-test',
      }),
    ).toString('base64url');
    const requestHeaders: HeadersInit[] = [
      {},
      { authorization: `Bearer test-header.${claims}.invalid-signature` },
    ];
    const t = convexTest(schema, modules);
    await t.action(async (ctx) => {
      const runMutation = vi.spyOn(ctx, 'runMutation');
      for (const headers of requestHeaders) {
        const request = new Request(`https://example.convex.site${path}`, {
          method: 'POST',
          headers,
          body: '{}',
        });
        // convex-test resolves identity independently of headers; HTTP actions reject.
        const response = await handler._handler(
          {
            ...ctx,
            auth: {
              getUserIdentity: vi
                .fn<ActionCtx['auth']['getUserIdentity']>()
                .mockRejectedValue(new Error('Invalid authentication token')),
            },
          },
          request,
        );
        expect(response.status).toBe(401);
        expect(request.bodyUsed).toBe(false);
      }
      expect(runMutation).not.toHaveBeenCalled();
    });
  });
});
