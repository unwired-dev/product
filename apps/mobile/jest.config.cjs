const path = require('node:path');
const { createRequire } = require('node:module');

const nativeRequire = createRequire(
  require.resolve('react-native/package.json'),
);

const expoPreset = require('jest-expo/jest-preset');

module.exports = {
  preset: 'jest-expo/ios',
  resolver: '<rootDir>/test/animation-resolver.cjs',
  testMatch: ['<rootDir>/test/**/*.test.tsx'],
  clearMocks: true,
  setupFiles: ['<rootDir>/test/native-registration.cjs'],
  setupFilesAfterEnv: ['<rootDir>/test/animations.cjs'],
  moduleNameMapper: {
    '^react-native-webview$': '<rootDir>/test/webview.tsx',
    '^expo-contacts$': '<rootDir>/test/contacts.ts',
    '/language-storage\\.ts$': '<rootDir>/test/language-storage.ts',
    // Package exports outside React Native's file layout, which the path mapping below would miss.
    '^react-native/(asset-registry|react-private-interface|setup-env|unstable-internals-do-not-use)$': `${path.dirname(require.resolve('react-native/package.json'))}/src/$1.js`,
    '^react-native($|/.*)': `${path.dirname(require.resolve('react-native/package.json'))}$1`,
    '^react($|/.*)': `${path.dirname(require.resolve('react/package.json'))}$1`,
    '^@react-native/virtualized-lists($|/.*)': `${path.dirname(nativeRequire.resolve('@react-native/virtualized-lists/package.json'))}$1`,
  },
  // @csstools publishes only ES modules, as .mjs files.
  transform: { '\\.mjs$': expoPreset.transform[String.raw`\.[jt]sx?$`] },
  transformIgnorePatterns: expoPreset.transformIgnorePatterns.map((pattern) =>
    pattern.replace(
      '|standard-navigation',
      '|standard-navigation|@private-email|@exodus|@csstools|effect|parse5|entities',
    ),
  ),
};
