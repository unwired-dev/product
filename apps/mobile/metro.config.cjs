const { getDefaultConfig } = require('expo/metro-config');
const { resolveSeed } = require('../../scripts/mock-mail-build.cjs');

const config = getDefaultConfig(__dirname);
config.resolver.resolveRequest = resolveSeed;
module.exports = config;
