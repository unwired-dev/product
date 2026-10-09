import { healthResponseFixture } from '@private-email/contracts/health';
import { convexTest } from 'convex-test';

import { api } from '../convex/_generated/api.js';
import schema from '../convex/schema.js';

const modules = import.meta.glob('../convex/**/*.ts');

describe('backend health action', () => {
  it('returns the shared health contract that clients decode', async () => {
    expect.assertions(1);
    vi.useFakeTimers({ now: healthResponseFixture.serverTime });
    try {
      await expect(
        convexTest(schema, modules).action(api.health.health, {}),
      ).resolves.toStrictEqual(healthResponseFixture);
    } finally {
      vi.useRealTimers();
    }
  });
});
