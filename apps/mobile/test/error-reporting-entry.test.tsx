let mockFailStartup = false;
jest.mock('../src/host.ts', () => ({
  errorReporting: { capture: jest.fn() },
}));
jest.mock('../src/registration.ts', () => {
  if (mockFailStartup) {
    throw new Error('synthetic startup failure');
  }
  return { start: jest.fn() };
});
jest.mock('../src/delivery.ts', () => {
  jest.requireMock('../src/registration.ts');
  return {};
});
jest.mock('../src/freshness.ts', () => ({}));
jest.mock('expo-router/entry', () => ({}));

/* oxlint-disable vitest/max-expects -- Each entrypoint journey preserves forwarding, direct handling and cleanup for the same exception. */
// Saved handlers model both installed RN paths; native handling is mocked.
it.each([
  { error: 'synthetic thrown string', startupFails: false },
  { error: new TypeError('Invalid time value'), startupFails: false },
  { error: new TypeError('Invalid time value'), startupFails: true },
])(
  'captures global and explicit exceptions after startup failure $startupFails',
  ({ error, startupFails }) => {
    expect.hasAssertions();
    jest.isolateModules(() => {
      const manager = jest.requireActual<{
        default: { handleException: (value: unknown, fatal: boolean) => void };
      }>('react-native/Libraries/Core/ExceptionsManager').default;
      const { errorReporting } = jest.requireMock<{
        errorReporting: { capture: jest.Mock };
      }>('../src/host.ts');
      const descriptor = Object.getOwnPropertyDescriptor(
        globalThis,
        'ErrorUtils',
      );
      const previous = jest.fn();
      const original = manager.handleException;
      manager.handleException = previous;
      let globalHandler = (value: unknown, fatal: boolean) => {
        manager.handleException(value, fatal);
      };
      const forwarding = jest.fn(globalHandler);
      globalHandler = forwarding;
      Object.defineProperty(globalThis, 'ErrorUtils', {
        configurable: true,
        value: {
          getGlobalHandler: () => globalHandler,
          setGlobalHandler: (handler: typeof globalHandler) => {
            globalHandler = handler;
          },
        },
      });
      try {
        mockFailStartup = startupFails;
        if (startupFails) {
          expect(() => jest.requireActual('../index.js')).toThrow(
            'synthetic startup failure',
          );
        } else {
          jest.requireActual('../index.js');
        }
        globalHandler(error, true);
        expect(errorReporting.capture).toHaveBeenCalledTimes(1);
        expect(forwarding).toHaveBeenCalledWith(error, true);
        expect(previous).toHaveBeenCalledWith(error, true);
        errorReporting.capture.mockClear();
        previous.mockClear();
        manager.handleException(error, false);
        expect(errorReporting.capture).toHaveBeenCalledTimes(1);
        expect(previous).toHaveBeenCalledWith(error, false);
        errorReporting.capture.mockClear();
        previous.mockClear();
        forwarding.mockImplementation(previous);
        globalHandler(error, false);
        expect(errorReporting.capture).toHaveBeenCalledTimes(1);
        expect(previous).toHaveBeenCalledWith(error, false);
        previous.mockImplementationOnce(() => {
          throw new Error('synthetic handler failure');
        });
        expect(() => globalHandler(error, true)).toThrow(
          'synthetic handler failure',
        );
        errorReporting.capture.mockClear();
        manager.handleException(error, false);
        expect(errorReporting.capture).toHaveBeenCalledTimes(1);
      } finally {
        mockFailStartup = false;
        manager.handleException = original;
        Object.defineProperty(
          globalThis,
          'ErrorUtils',
          descriptor ?? {
            configurable: true,
            value: undefined,
          },
        );
      }
    });
  },
);
