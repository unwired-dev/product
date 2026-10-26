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

// Without a native stack, a stack screen appears once it mounts.
jest.mock('react-native-screens', () => {
  const React = require('react');
  const { Pressable } = require('react-native');
  const screens = jest.requireActual('react-native-screens');
  function ScreenStack({ children, ...props }) {
    const pages = React.Children.toArray(children).filter(React.isValidElement);
    return React.createElement(
      screens.ScreenStack,
      props,
      pages.map((page, index) =>
        React.cloneElement(page, { headerActive: index === pages.length - 1 }),
      ),
    );
  }
  function ScreenStackItem({
    onAppear,
    headerActive = true,
    headerConfig,
    children,
    ...props
  }) {
    const appear = React.useRef(onAppear);
    React.useEffect(() => {
      appear.current?.();
    }, []);
    // UIKit shows only the top screen's bar and dispatches its native item actions.
    const buttons = headerActive
      ? [
          ...(headerConfig?.headerLeftBarButtonItems ?? []),
          ...(headerConfig?.headerRightBarButtonItems ?? []),
        ]
      : [];
    return React.createElement(
      screens.ScreenStackItem,
      {
        ...props,
        headerConfig: headerActive
          ? headerConfig
          : { ...headerConfig, children: undefined },
      },
      children,
      buttons?.map((item, index) =>
        item.type === 'button'
          ? React.createElement(Pressable, {
              key: index,
              accessibilityRole: 'button',
              accessibilityLabel: item.accessibilityLabel ?? item.title,
              accessibilityState: { disabled: item.disabled === true },
              disabled: item.disabled,
              onPress: item.onPress,
            })
          : null,
      ),
    );
  }
  return { ...screens, ScreenStack, ScreenStackItem };
});

// Without SwiftUI, a sheet shows its content while presented and finishes dismissing at once.
jest.mock('@expo/ui/swift-ui', () => {
  const React = require('react');
  function Passthrough({ children }) {
    return React.createElement(React.Fragment, null, children);
  }
  function BottomSheet({ isPresented, onDismiss, children }) {
    const [shown, setShown] = React.useState(isPresented);
    if (isPresented && !shown) {
      setShown(true);
    }
    React.useEffect(() => {
      if (shown && !isPresented) {
        setShown(false);
        onDismiss?.();
      }
    }, [shown, isPresented, onDismiss]);
    return shown ? children : null;
  }
  // An alert shows its title, message and actions while presented.
  function Alert({ testID, title, isPresented, children }) {
    const { Text, View } = require('react-native');
    return isPresented
      ? React.createElement(
          View,
          { testID, accessibilityViewIsModal: true },
          React.createElement(Text, { accessibilityRole: 'header' }, title),
          children,
        )
      : null;
  }
  Alert.Trigger = Passthrough;
  Alert.Actions = Passthrough;
  Alert.Message = Passthrough;
  function Button({ label, onPress }) {
    const { Pressable, Text } = require('react-native');
    return React.createElement(
      Pressable,
      { accessibilityRole: 'button', accessibilityLabel: label, onPress },
      React.createElement(Text, null, label),
    );
  }
  return {
    Alert,
    BottomSheet,
    Button,
    Text: require('react-native').Text,
    Group: Passthrough,
    Host: Passthrough,
    RNHostView: Passthrough,
    Spacer: () => null,
  };
});
jest.mock('@expo/ui/swift-ui/modifiers', () => ({
  frame: (params) => ({ $type: 'frame', ...params }),
  presentationBackground: (style) => ({
    $type: 'presentationBackground',
    style,
  }),
  presentationDetents: (detents) => ({ $type: 'presentationDetents', detents }),
}));

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
