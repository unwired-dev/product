/* oxlint-disable vitest/prefer-import-in-mock -- Jest 29 module mocks require string names. */
jest.mock('../src/host.ts', () => ({
  errorReporting: { capture: jest.fn() },
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
/* oxlint-enable vitest/prefer-import-in-mock */

function loadEntrypoint() {
  try {
    jest.requireActual('../index.js');
    return { kind: 'loaded' };
  } catch (error) {
    return { kind: 'failed', error };
  }
}

function restoreErrorUtils(
  descriptor: Readonly<PropertyDescriptor> | undefined,
) {
  if (descriptor === undefined) {
    Reflect.deleteProperty(globalThis, 'ErrorUtils');
  } else {
    Object.defineProperty(globalThis, 'ErrorUtils', descriptor);
  }
}

/* oxlint-disable vitest/max-expects -- Each entrypoint journey preserves forwarding, direct handling and cleanup for the same exception. */
// Saved handlers model both installed RN paths; native handling is mocked.
describe.each([
  {
    name: 'a thrown string after normal startup',
    error: 'synthetic thrown string',
    startupFails: false,
    startupResult: { kind: 'loaded' },
  },
  {
    name: 'a TypeError after normal startup',
    error: new TypeError('Invalid time value'),
    startupFails: false,
    startupResult: { kind: 'loaded' },
  },
  {
    name: 'a TypeError after failed startup',
    error: new TypeError('Invalid time value'),
    startupFails: true,
    startupResult: {
      kind: 'failed',
      error: new Error('synthetic startup failure'),
    },
  },
])('$name', ({ error, startupFails, startupResult }) => {
  beforeEach(() => {
    // oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest 29 module mocks require string names.
    jest.doMock('../src/registration.ts', () => {
      if (startupFails) {
        throw new Error('synthetic startup failure');
      }
      return { start: jest.fn() };
    });
  });

  it('captures global and explicit exceptions with forwarding and cleanup', () => {
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
      let globalHandler = (value: unknown, fatal: boolean) => {
        manager.handleException(value, fatal);
      };
      const forwarding = jest.fn(globalHandler);
      globalHandler = forwarding;
      try {
        manager.handleException = previous;
        Object.defineProperty(globalThis, 'ErrorUtils', {
          configurable: true,
          value: {
            getGlobalHandler: () => globalHandler,
            setGlobalHandler: (handler: typeof globalHandler) => {
              globalHandler = handler;
            },
          },
        });
        expect(loadEntrypoint()).toStrictEqual(startupResult);
        globalHandler(error, true);
        expect(errorReporting.capture.mock.calls).toHaveLength(1);
        expect(forwarding).toHaveBeenCalledWith(error, true);
        expect(previous).toHaveBeenCalledWith(error, true);
        errorReporting.capture.mockClear();
        previous.mockClear();
        manager.handleException(error, false);
        expect(errorReporting.capture.mock.calls).toHaveLength(1);
        expect(previous).toHaveBeenCalledWith(error, false);
        errorReporting.capture.mockClear();
        previous.mockClear();
        forwarding.mockImplementation(previous);
        globalHandler(error, false);
        expect(errorReporting.capture.mock.calls).toHaveLength(1);
        expect(previous).toHaveBeenCalledWith(error, false);
        previous.mockImplementationOnce(() => {
          throw new Error('synthetic handler failure');
        });
        expect(() => globalHandler(error, true)).toThrow(
          'synthetic handler failure',
        );
        errorReporting.capture.mockClear();
        manager.handleException(error, false);
        expect(errorReporting.capture.mock.calls).toHaveLength(1);
      } finally {
        manager.handleException = original;
        restoreErrorUtils(descriptor);
      }
    });
  });
});
