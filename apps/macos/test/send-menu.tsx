import { ok } from 'node:assert/strict';

import { fireEvent, screen } from '@testing-library/react-native';
import * as Predicate from 'effect/Predicate';

interface SendMenu {
  readonly sections: ReadonlyArray<{
    readonly items: ReadonlyArray<{
      readonly id: string;
      readonly title: string;
      readonly subtitle?: string;
      readonly disabled?: boolean;
    }>;
  }>;
}
const isSendMenu = (props: unknown): props is SendMenu =>
  Predicate.hasProperty(props, 'sections');

// The Send menu, the system context menu a right click on Send opens: Send and Send Now, then
// Remind Me to Send….
const sendMenu = () => {
  let menu = screen.getByRole('button', { name: 'Send' }).parent;
  while (menu !== null && menu.type !== 'UnwiredContextMenu') {
    menu = menu.parent;
  }
  ok(menu, 'Expected the Send menu');
  expect(menu).toHaveProp('sections', [
    {
      items: [
        expect.objectContaining({ id: 'send', title: 'Send' }),
        expect.objectContaining({ id: 'sendNow' }),
      ],
    },
    {
      items: [
        expect.objectContaining({ id: 'remind', title: 'Remind Me to Send…' }),
      ],
    },
  ]);
  return menu;
};

// The Send menu's item `id` as AppKit receives it, and choosing it.
export const sendMenuItem = (id: string) => {
  const menu = sendMenu();
  const { props }: { props: unknown } = menu;
  ok(isSendMenu(props));
  const item = props.sections
    .flatMap(({ items }) => items)
    .find((candidate) => candidate.id === id);
  ok(item, `Expected ${id} in the Send menu`);
  return {
    ...item,
    choose: async () => {
      await fireEvent(menu, 'select', { nativeEvent: { id } });
    },
  };
};

// Chooses Remind Me to Send… in the Send menu.
export const remindFromSendMenu = async () => {
  await sendMenuItem('remind').choose();
};
