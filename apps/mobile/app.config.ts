import type { ExpoConfig } from 'expo/config';

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
  },
  plugins: [
    'expo-router',
    [
      'expo-build-properties',
      { ios: { deploymentTarget: '27.0', enableSceneSupport: true } },
    ],
  ],
};

export default config;
