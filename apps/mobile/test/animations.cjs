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

// Without SwiftUI, presenters retain hidden content like the installed Expo views. The system's
// accessibility escape dismisses them; a sheet finishes dismissing at once.
jest.mock('@expo/ui/swift-ui', () => {
  const React = require('react');
  const { Pressable, Text, View } = require('react-native');
  function Passthrough({ children }) {
    return React.createElement(React.Fragment, null, children);
  }
  function Presented({ testID, shown = true, onIsPresentedChange, children }) {
    return React.createElement(
      View,
      {
        testID,
        style: shown ? undefined : { display: 'none' },
        onAccessibilityEscape: () => {
          onIsPresentedChange?.(false);
        },
      },
      children,
    );
  }
  function BottomSheet({
    isPresented,
    onIsPresentedChange,
    onDismiss,
    children,
  }) {
    const [shown, setShown] = React.useState(isPresented);
    const [mounted, setMounted] = React.useState(isPresented);
    if (isPresented && !mounted) {
      setMounted(true);
    }
    if (isPresented && !shown) {
      setShown(true);
    }
    React.useEffect(() => {
      if (shown && !isPresented) {
        setShown(false);
        onDismiss?.();
      }
    }, [shown, isPresented, onDismiss]);
    return mounted
      ? React.createElement(
          Presented,
          { testID: 'bottom-sheet', shown, onIsPresentedChange },
          children,
        )
      : null;
  }
  // An alert shows its title, message and actions while presented.
  function Alert({ testID, title, isPresented, children }) {
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
  // Form controls render their text, and a button its pressable label, for component journeys.
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
  function Button({ label, onPress, modifiers, children }) {
    return React.createElement(
      Pressable,
      {
        accessibilityRole: 'button',
        onPress,
        disabled: modifiers?.some(
          (each) => each.$type === 'disabled' && each.disabled,
        ),
      },
      label === undefined ? children : React.createElement(Text, null, label),
    );
  }
  // A menu picker lists its options as radios; each option's tag modifier is its value.
  function Picker({
    label,
    selection,
    onSelectionChange,
    modifiers,
    children,
  }) {
    const disabled = modifiers?.some(
      (modifier) => modifier.$type === 'disabled' && modifier.disabled,
    );
    return React.createElement(
      View,
      { accessibilityLabel: label, accessibilityRole: 'radiogroup' },
      React.Children.map(children, (option) => {
        const value = option.props.modifiers.find(
          (modifier) => modifier.$type === 'tag',
        ).tag;
        return React.createElement(
          Pressable,
          {
            accessibilityRole: 'radio',
            accessibilityState: { checked: value === selection, disabled },
            disabled,
            onPress: () => {
              onSelectionChange?.(value);
            },
          },
          React.createElement(Text, null, option.props.children),
        );
      }),
    );
  }
  // A popover keeps its trigger in place and presents its content beside it.
  function Popover({ isPresented, onIsPresentedChange, children }) {
    return React.Children.map(children, (child) => {
      if (child.type !== Popover.Content) {
        return child;
      }
      return React.createElement(
        Presented,
        { testID: 'popover', shown: isPresented, onIsPresentedChange },
        child,
      );
    });
  }
  // A distinct component, so Popover can tell its content from its trigger.
  function Content({ children }) {
    return React.createElement(React.Fragment, null, children);
  }
  Popover.Trigger = Passthrough;
  Popover.Content = Content;
  // Substitute only the native appearance event; it is separate from RN layout.
  function Group({ modifiers, children }) {
    return React.createElement(
      View,
      {
        onAppear: () => {
          for (const modifier of modifiers ?? []) {
            if (modifier.$type === 'onAppear') {
              modifier.eventListener({});
            }
          }
        },
      },
      children,
    );
  }
  return {
    Alert,
    BottomSheet,
    Button,
    Form: Passthrough,
    Popover,
    Group,
    Host: Passthrough,
    HStack: Passthrough,
    Label: Labeled,
    LabeledContent: Labeled,
    Picker,
    ProgressView: () => null,
    RNHostView: Passthrough,
    Section,
    Spacer: () => null,
    Text,
    VStack: Passthrough,
  };
});
jest.mock('@expo/ui/swift-ui/modifiers', () => ({
  buttonBorderShape: (shape) => ({ $type: 'buttonBorderShape', shape }),
  buttonStyle: (style) => ({ $type: 'buttonStyle', style }),
  contentShape: (shape) => ({ $type: 'contentShape', shape }),
  controlSize: (size) => ({ $type: 'controlSize', size }),
  labelStyle: (style) => ({ $type: 'labelStyle', style }),
  disabled: (disabled) => ({ $type: 'disabled', disabled }),
  font: (params) => ({ $type: 'font', ...params }),
  foregroundStyle: (style) => ({ $type: 'foregroundStyle', style }),
  frame: (params) => ({ $type: 'frame', ...params }),
  listRowBackground: (color) => ({ $type: 'listRowBackground', color }),
  monospacedDigit: () => ({ $type: 'monospacedDigit' }),
  onAppear: (eventListener) => ({ $type: 'onAppear', eventListener }),
  padding: (params) => ({ $type: 'padding', ...params }),
  pickerStyle: (style) => ({ $type: 'pickerStyle', style }),
  scrollContentBackground: (visible) => ({
    $type: 'scrollContentBackground',
    visible,
  }),
  shapes: { rectangle: () => ({ type: 'rectangle' }) },
  tag: (tag) => ({ $type: 'tag', tag }),
  tint: (tint) => ({ $type: 'tint', tint }),
  presentationBackground: (style) => ({
    $type: 'presentationBackground',
    style,
  }),
  presentationDetents: (detents) => ({ $type: 'presentationDetents', detents }),
  presentationDragIndicator: (visibility) => ({
    $type: 'presentationDragIndicator',
    visibility,
  }),
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
