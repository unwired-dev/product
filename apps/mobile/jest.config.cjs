const expoPreset = require('jest-expo/jest-preset');

module.exports = {
  preset: 'jest-expo/ios',
  testMatch: ['<rootDir>/test/**/*.test.tsx'],
  clearMocks: true,
  transformIgnorePatterns: expoPreset.transformIgnorePatterns.map((pattern) =>
    pattern.replace(
      '|standard-navigation',
      '|standard-navigation|@private-email|effect',
    ),
  ),
};
