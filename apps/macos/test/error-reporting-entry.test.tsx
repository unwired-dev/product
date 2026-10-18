jest.mock('../src/registration.ts', () => ({
  errorReporting: { capture: jest.fn() },
  start: jest.fn(),
}));
jest.mock('../src/delivery.ts', () => ({}));
jest.mock('../src/freshness.ts', () => ({ keepGmailFresh: jest.fn() }));
jest.mock('../src/window.tsx', () => ({
  InboxWindow: jest.fn(),
  SettingsWindowRoot: jest.fn(),
}));
jest.mock('@private-email/mail-core/registration-mode', () => ({
  previewInbox: true,
}));

/* oxlint-disable vitest/max-expects -- Each entrypoint journey preserves forwarding, direct handling and cleanup for the same exception. */
// Saved handlers model both installed RN paths; native handling is mocked.
it.each(['synthetic thrown string', new TypeError('Invalid time value')])(
  'captures global and explicit exception forwarding once for %s',
  (error) => {
    expect.hasAssertions();
    jest.isolateModules(() => {
      const manager = jest.requireActual<{
        default: { handleException: (value: unknown, fatal: boolean) => void };
      }>('react-native/Libraries/Core/ExceptionsManager').default;
      const { errorReporting } = jest.requireMock<{
        errorReporting: { capture: jest.Mock };
      }>('../src/registration.ts');
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
        jest.requireActual('../index.js');
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
        manager.handleException = original;
        Object.defineProperty(globalThis, 'ErrorUtils', descriptor ?? {
          configurable: true,
          value: undefined,
        });
      }
    });
  },
);
