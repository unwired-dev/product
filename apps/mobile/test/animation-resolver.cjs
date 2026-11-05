// Native Worklets is unavailable in Jest. Mirrors react-native-reanimated/jest/resolver, whose
// path test also matches any pnpm directory naming Worklets as a peer, Reanimated's own included:
// Worklets and these Reanimated modules use their web files; everything else keeps Expo's iOS
// resolution.
const reanimatedWebModules =
  /\/(?:initializers|mutables|mappers|ConfigHelper|UpdateLayoutAnimations|useAnimatedRef|useAnimatedStyle|WorkletEventHandler|JSPropsUpdater|updateProps|util|css\/component\/AnimatedComponent)$/u;

const usesWeb = (request, basedir) => {
  if (request.startsWith('react-native-worklets')) {
    return true;
  }
  if (basedir.includes('/react-native-worklets/')) {
    return true;
  }
  return (
    request.startsWith('.') &&
    reanimatedWebModules.test(request) &&
    basedir.includes('/react-native-reanimated/')
  );
};

module.exports = function animationResolver(request, options) {
  return options.defaultResolver(
    request,
    usesWeb(request, options.basedir)
      ? {
          ...options,
          extensions: options.extensions.filter(
            (extension) => !extension.includes('native'),
          ),
        }
      : options,
  );
};
