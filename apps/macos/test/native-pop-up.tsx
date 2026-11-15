import type { ComponentProps } from 'react';

import { Pressable } from 'react-native';

import { unwiredMenu } from './native-menu.ts';

// `UnwiredPopUpButton` at the Jest native boundary. A press opens its AppKit menu with the items it
// shows then, which a test answers through `native-menu.ts`; a choice reports the item's id.
export function NativePopUpButton({
  sections,
  enabled,
  onSelect,
  ...props
}: ComponentProps<typeof Pressable> & {
  readonly sections: Parameters<typeof unwiredMenu.show>[1];
  readonly enabled: boolean;
  readonly onSelect: (event: {
    readonly nativeEvent: { readonly id: string };
  }) => void;
}) {
  const open = async () => {
    const id = await unwiredMenu.show(0, sections);
    if (id !== null) {
      onSelect({ nativeEvent: { id } });
    }
  };
  return (
    <Pressable
      {...props}
      disabled={!enabled}
      onPress={() => {
        // AppKit tracks the menu after the click returns.
        void open();
      }}
    />
  );
}

// `UnwiredSplitButton` at the Jest native boundary: pressing it runs its label, and its arrow,
// labelled `menuLabel`, opens its AppKit menu as `NativePopUpButton` does.
export function NativeSplitButton({
  sections,
  enabled,
  menuLabel,
  onPress,
  onSelect,
  ...props
}: ComponentProps<typeof Pressable> & {
  readonly sections: Parameters<typeof unwiredMenu.show>[1];
  readonly enabled: boolean;
  readonly menuLabel: string;
  readonly onPress: () => void;
  readonly onSelect: (event: {
    readonly nativeEvent: { readonly id: string };
  }) => void;
}) {
  return (
    <>
      <Pressable
        {...props}
        disabled={!enabled}
        onPress={onPress}
      />
      <NativePopUpButton
        accessibilityLabel={menuLabel}
        accessibilityRole="button"
        sections={sections}
        enabled={enabled}
        onSelect={onSelect}
      />
    </>
  );
}
