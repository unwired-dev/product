module.exports = {
  preset: 'react-native-macos',
  testMatch: ['<rootDir>/test/**/*.test.tsx'],
  moduleNameMapper: {
    '^@react-native-clipboard/clipboard$':
      '@react-native-clipboard/clipboard/jest/clipboard-mock.js',
    '^react-native-webview$': '<rootDir>/test/webview.tsx',
    '/language-storage\\.ts$': '<rootDir>/test/language-storage.ts',
    '^react-native$': 'react-native-macos',
    '^react-native/(.*)$': 'react-native-macos/$1',
  },
  transformIgnorePatterns: [
    'node_modules/(?!(?:.pnpm/)?(?:react-native|@react-native|@private-email|@exodus|effect|parse5|entities))',
  ],
};
