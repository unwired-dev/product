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
  return name === 'SettingsManager' ? settingsManager : getEnforcing(name);
};

jest.mock('react-native-keyboard-controller', () =>
  require('react-native-keyboard-controller/jest'),
);
