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
TurboModuleRegistry.getEnforcing = (name) =>
  name === 'UnwiredRegistration' ? unwiredRegistration : getEnforcing(name);

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name; the package ships its own mock.
jest.mock('react-native-keyboard-controller', () =>
  require('react-native-keyboard-controller/jest'),
);
