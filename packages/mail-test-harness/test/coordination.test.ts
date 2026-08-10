import { startMailTestCoordinator } from '../src/coordination.ts';

describe('mail-test milestone coordination', () => {
  it('runs injection once after the client reports initial synchronization', async () => {
    expect.assertions(4);
    let injectionCount = 0;
    const onInitialSynchronization = async (): Promise<void> => {
      injectionCount += 1;
    };
    const coordinator = await startMailTestCoordinator({
      onInitialSynchronization,
      runId: '00000000-0000-0000-0000-000000000001',
    });
    try {
      const response = await fetch(coordinator.url, { method: 'POST' });
      expect(response.status).toBe(204);
      await expect(coordinator.verifyCompleted()).resolves.toBeUndefined();
      expect(injectionCount).toBe(1);

      const duplicate = await fetch(coordinator.url, { method: 'POST' });
      expect(duplicate.status).toBe(409);
    } finally {
      await coordinator.close();
    }
  });

  it('preserves a phase-specific injection failure', async () => {
    expect.assertions(2);
    const coordinator = await startMailTestCoordinator({
      onInitialSynchronization: async () => {
        throw new Error('provider did not observe the injected message');
      },
      runId: '00000000-0000-0000-0000-000000000001',
    });
    try {
      const response = await fetch(coordinator.url, { method: 'POST' });
      expect(response.status).toBe(500);
      await expect(coordinator.verifyCompleted()).rejects.toThrow(
        'injection or provider observation failed',
      );
    } finally {
      await coordinator.close();
    }
  });
});
