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
  // Form controls render their text, and a button its pressable label, for component journeys.
  const { Pressable, Text } = require('react-native');
  function Section({ title, header, footer, children }) {
    return React.createElement(
      React.Fragment,
      null,
      title === undefined ? header : React.createElement(Text, null, title),
      children,
      footer,
    );
  }
  function Labeled({ label, title, children }) {
    return React.createElement(
      React.Fragment,
      null,
      typeof (label ?? title) === 'string'
        ? React.createElement(Text, null, label ?? title)
        : label,
      children,
    );
  }
  function Button({ label, onPress, modifiers }) {
    return React.createElement(
      Pressable,
      {
        accessibilityRole: 'button',
        onPress,
        disabled: modifiers?.some(
          (each) => each.$type === 'disabled' && each.disabled,
        ),
      },
      React.createElement(Text, null, label),
    );
  }
  function Picker({ label, selection, onSelectionChange, children }) {
    return React.createElement(
      Pressable,
      {
        accessibilityLabel: label,
        accessibilityValue: { text: selection },
        onSelectionChange,
      },
      React.createElement(Text, null, label),
      children,
    );
  }
  return {
    BottomSheet,
    Button,
    Form: Passthrough,
    Group: Passthrough,
    Host: Passthrough,
    Label: Labeled,
    LabeledContent: Labeled,
    Picker,
    ProgressView: () => null,
    RNHostView: Passthrough,
    Section,
    Text,
    VStack: Passthrough,
  };
});
jest.mock('@expo/ui/swift-ui/modifiers', () => ({
  disabled: (disabled) => ({ $type: 'disabled', disabled }),
  foregroundStyle: (style) => ({ $type: 'foregroundStyle', style }),
  listRowBackground: (color) => ({ $type: 'listRowBackground', color }),
  monospacedDigit: () => ({ $type: 'monospacedDigit' }),
  scrollContentBackground: (visible) => ({
    $type: 'scrollContentBackground',
    visible,
  }),
  tag: (tag) => ({ $type: 'tag', tag }),
  tint: (tint) => ({ $type: 'tint', tint }),
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
