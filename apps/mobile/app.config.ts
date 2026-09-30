import { env } from 'node:process';

import type { ExpoConfig } from 'expo/config';

const mockScenario: unknown = env.UNWIRED_MOCK_SCENARIO;
if (
  mockScenario !== undefined &&
  mockScenario !== '' &&
  mockScenario !== 'open-read-relaunch' &&
  mockScenario !== 'mail-unavailable'
) {
  throw new Error('Unknown Mock Mail Session scenario');
}

const config: ExpoConfig = {
  name: 'Unwired Mail Preview',
  slug: 'unwired-mail-preview',
  scheme: 'unwired-mail-preview',
  version: '0.1.0',
  platforms: ['ios'],
  userInterfaceStyle: 'automatic',
  ios: {
    bundleIdentifier: 'dev.unwired.mail.preview',
    supportsTablet: true,
    infoPlist: mockScenario ? { UnwiredMockScenario: mockScenario } : {},
  },
  plugins: [
    'expo-router',
    './plugins/private-inbox.cjs',
    [
      'expo-build-properties',
      { ios: { deploymentTarget: '27.0', enableSceneSupport: true } },
    ],
  ],
};

export default config;
