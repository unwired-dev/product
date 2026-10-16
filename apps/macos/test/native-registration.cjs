const { TurboModuleRegistry } = require('react-native');

// `UnwiredRegistration` as a device that saved nothing answers the reads screens make on their
// own. Journeys that exercise the module substitute it.
const unwiredRegistration = {
  getConstants: () => ({}),
  mailAssistance: () => Promise.resolve({ owner: null, profiles: [] }),
};
const { getEnforcing } = TurboModuleRegistry;
TurboModuleRegistry.getEnforcing = (name) =>
  name === 'UnwiredRegistration' ? unwiredRegistration : getEnforcing(name);
