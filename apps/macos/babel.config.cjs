module.exports = {
  presets: [
    ['module:@react-native/babel-preset', { enableBabelRuntime: false }],
  ],
  // parse5 publishes `export * as` re-exports, which this React Native preset does not lower.
  plugins: ['@babel/plugin-transform-export-namespace-from'],
};
