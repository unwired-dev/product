module.exports = {
  preset: 'react-native-macos',
  testMatch: ['<rootDir>/test/**/*.test.tsx'],
  setupFiles: ['<rootDir>/test/native-registration.cjs'],
  moduleNameMapper: {
    '^@react-native-clipboard/clipboard$':
      '@react-native-clipboard/clipboard/jest/clipboard-mock.js',
    '^react-native-webview$': '<rootDir>/test/webview.tsx',
    '/language-storage\\.ts$': '<rootDir>/test/language-storage.ts',
    '^react-native$': 'react-native-macos',
    '^react-native/(.*)$': 'react-native-macos/$1',
  },
  // @csstools publishes only ES modules, as .mjs files.
  transform: { '\\.mjs$': 'babel-jest' },
  transformIgnorePatterns: [
    'node_modules/(?!(?:.pnpm/)?(?:react-native|@react-native|@private-email|@exodus|@csstools|effect|parse5|entities))',
  ],
};
