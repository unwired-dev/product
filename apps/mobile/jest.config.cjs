const path = require('node:path');
const { createRequire } = require('node:module');

const nativeRequire = createRequire(
  require.resolve('react-native/package.json'),
);

const expoPreset = require('jest-expo/jest-preset');

module.exports = {
  preset: 'jest-expo/ios',
  testMatch: ['<rootDir>/test/**/*.test.tsx'],
  clearMocks: true,
  moduleNameMapper: {
    '^react-native-webview$': '<rootDir>/test/webview.tsx',
    '/language-storage\\.ts$': '<rootDir>/test/language-storage.ts',
    '^react-native($|/.*)': `${path.dirname(require.resolve('react-native/package.json'))}$1`,
    '^react($|/.*)': `${path.dirname(require.resolve('react/package.json'))}$1`,
    '^@react-native/virtualized-lists($|/.*)': `${path.dirname(nativeRequire.resolve('@react-native/virtualized-lists/package.json'))}$1`,
  },
  transformIgnorePatterns: expoPreset.transformIgnorePatterns.map((pattern) =>
    pattern.replace(
      '|standard-navigation',
      '|standard-navigation|@private-email|effect|parse5|entities',
    ),
  ),
};
