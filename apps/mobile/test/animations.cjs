const { TextDecoder } = require('node:util');
const { Animated, Modal } = require('react-native');

// The preset installs Expo's UTF-8-only decoder beside Node's Buffer, a pairing no device has;
// @exodus/bytes then trusts it as native and fails to load. Packaged builds verify device decoding.
globalThis.TextDecoder = TextDecoder;

// The preset's native Modal substitute omits iOS's dismissal-completion event.
Modal.prototype.componentDidUpdate = function (previous) {
  if (previous.visible === true && this.props.visible === false) {
    this.props.onDismiss?.();
  }
};

// Component journeys substitute the native animation driver with its completed frame.
// Native journeys remain responsible for motion timing and appearance.
beforeEach(() => {
  jest.spyOn(Animated, 'timing').mockImplementation((value, { toValue }) => ({
    start: (complete) => {
      value.setValue(toValue);
      complete?.({ finished: true });
    },
    stop: () => undefined,
    reset: () => undefined,
  }));
});
