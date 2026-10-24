const { TurboModuleRegistry } = require('react-native');

// `UnwiredRegistration` as a device that saved nothing answers the reads screens make on their
// own. Journeys that exercise the module substitute it.
const unwiredRegistration = {
  getConstants: () => ({}),
  mailAssistance: () => Promise.resolve({ owner: null, profiles: [] }),
  preference: () => Promise.resolve({ value: null }),
  setPreference: () => Promise.resolve({}),
};
const { getEnforcing } = TurboModuleRegistry;
// `UnwiredMenu` and `UnwiredAlert` each track one menu or sheet at a time until the journey answers
// it. They load with the journey, once Testing Library can.
TurboModuleRegistry.getEnforcing = (name) => {
  if (name === 'UnwiredRegistration') {
    return unwiredRegistration;
  }
  if (name === 'UnwiredAlert') {
    return require('./native-alert.ts').unwiredAlert;
  }
  return name === 'UnwiredMenu'
    ? require('./native-menu.ts').unwiredMenu
    : getEnforcing(name);
};

// `UnwiredPopUpButton` opens its menu through `UnwiredMenu` above when pressed; other native
// components keep the React Native preset's mock.
jest.mock(
  'react-native-macos/Libraries/ReactNative/requireNativeComponent',
  () => {
    const requireNativeComponent = jest.requireActual(
      'react-native-macos/jest/mocks/requireNativeComponent',
    ).default;
    return {
      __esModule: true,
      default: (name) =>
        name === 'UnwiredPopUpButton'
          ? require('./native-pop-up.tsx').NativePopUpButton
          : requireNativeComponent(name),
    };
  },
);
