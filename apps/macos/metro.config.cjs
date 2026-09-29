const path = require('node:path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

const macos = path.dirname(require.resolve('react-native-macos/package.json'));
const react = path.dirname(require.resolve('react/package.json'));

module.exports = mergeConfig(getDefaultConfig(__dirname), {
  watchFolders: [path.resolve(__dirname, '../..')],
  transformer: { enableBabelRuntime: false },
  serializer: {
    getModulesRunBeforeMainModule: () => [
      path.join(macos, 'Libraries/Core/InitializeCore.js'),
    ],
  },
  resolver: {
    platforms: ['macos'],
    resolveRequest(context, moduleName, platform) {
      if (
        moduleName === 'react-native' ||
        moduleName.startsWith('react-native/')
      ) {
        return context.resolveRequest(
          context,
          moduleName.replace(/^react-native/u, macos),
          platform,
        );
      }
      if (moduleName === 'react' || moduleName.startsWith('react/')) {
        return context.resolveRequest(
          context,
          moduleName.replace(/^react/u, react),
          platform,
        );
      }
      return context.resolveRequest(context, moduleName, platform);
    },
  },
});
