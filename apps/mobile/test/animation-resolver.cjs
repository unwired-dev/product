// Native Worklets is unavailable in Jest; keep the rest of Expo's iOS resolution.
module.exports = function animationResolver(request, options) {
  const animation = ['react-native-reanimated', 'react-native-worklets'].some(
    (name) => options.basedir.includes(`/${name}/`),
  );
  const extensions = animation
    ? options.extensions.flatMap((extension) =>
        /^\.(?:native|ios|android)\./u.test(extension)
          ? []
          : [`.web${extension}`, extension],
      )
    : options.extensions;
  return options.defaultResolver(request, { ...options, extensions });
};
