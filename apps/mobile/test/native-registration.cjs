const { TurboModuleRegistry } = require('react-native');

// `UnwiredRegistration` as a device that saved nothing answers the reads screens make on their
// own. Journeys that exercise the module substitute it.
const unwiredRegistration = {
  getConstants: () => ({}),
  mailAssistance: () => Promise.resolve({ owner: null, profiles: [] }),
  preference: () => Promise.resolve({ value: null }),
  setPreference: () => Promise.resolve({}),
};
// `SettingsManager` as the device's user defaults, empty when a test file starts.
const userDefaults = {};
const settingsManager = {
  getConstants: () => ({ settings: userDefaults }),
  setValues: (values) => Object.assign(userDefaults, values),
};
const { getEnforcing } = TurboModuleRegistry;
TurboModuleRegistry.getEnforcing = (name) => {
  if (name === 'UnwiredRegistration') {
    return unwiredRegistration;
  }
  if (name === 'UnwiredStatusBar') {
    return { refresh: () => undefined };
  }
  return name === 'SettingsManager' ? settingsManager : getEnforcing(name);
};

jest.mock('react-native-keyboard-controller', () =>
  require('react-native-keyboard-controller/jest'),
);

// `UnwiredCloseQuestion` shows its system action sheet's answers as buttons while open; other
// native components keep the React Native preset's mock.
jest.mock('react-native/Libraries/ReactNative/requireNativeComponent', () => {
  const requireNativeComponent = jest.requireActual(
    require.resolve(
      '@react-native/jest-preset/jest/mocks/requireNativeComponent',
      {
        paths: [require.resolve('jest-expo/package.json')],
      },
    ),
  ).default;
  return {
    __esModule: true,
    default: (name) =>
      name === 'UnwiredCloseQuestion'
        ? require('./close-question.tsx').NativeCloseQuestion
        : requireNativeComponent(name),
  };
});
