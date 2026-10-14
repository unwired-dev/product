module.exports = {
  preset: 'react-native-macos',
  testMatch: ['<rootDir>/test/**/*.test.tsx'],
  // The shared CI runner takes seconds to warm up the first composer journey.
  testTimeout: 30_000,
  moduleNameMapper: {
    '^react-native-webview$': '<rootDir>/test/webview.tsx',
    '/language-storage\\.ts$': '<rootDir>/test/language-storage.ts',
    '^react-native$': 'react-native-macos',
    '^react-native/(.*)$': 'react-native-macos/$1',
  },
  transformIgnorePatterns: [
    'node_modules/(?!(?:.pnpm/)?(?:react-native|@react-native|@private-email|effect|parse5|entities))',
  ],
};
