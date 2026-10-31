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
