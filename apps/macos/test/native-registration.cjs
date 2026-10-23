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
// `UnwiredMenu` tracks one menu at a time until the journey answers it. It loads with the
// journey, once Testing Library can.
TurboModuleRegistry.getEnforcing = (name) => {
  if (name === 'UnwiredRegistration') {
    return unwiredRegistration;
  }
  return name === 'UnwiredMenu'
    ? require('./native-menu.ts').unwiredMenu
    : getEnforcing(name);
};
