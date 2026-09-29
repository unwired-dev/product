module.exports = {
  preset: 'react-native-macos',
  testMatch: ['<rootDir>/test/**/*.test.tsx'],
  moduleNameMapper: {
    '^react-native$': 'react-native-macos',
    '^react-native/(.*)$': 'react-native-macos/$1',
  },
  transformIgnorePatterns: [
    'node_modules/(?!(?:.pnpm/)?(?:react-native|@react-native|@private-email|effect))',
  ],
};
