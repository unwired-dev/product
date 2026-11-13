import { ok } from 'node:assert/strict';

import { fireEvent, screen } from '@testing-library/react-native';

// Chooses Remind Me to Send… in the Send menu, the system context menu a right click on Send
// opens, after Send itself.
export const remindFromSendMenu = async () => {
  let menu = screen.getByRole('button', { name: 'Send' }).parent;
  while (menu !== null && menu.type !== 'UnwiredContextMenu') {
    menu = menu.parent;
  }
  ok(menu, 'Expected the Send menu');
  expect(menu).toHaveProp('sections', [
    { items: [expect.objectContaining({ id: 'send', title: 'Send' })] },
    {
      items: [
        expect.objectContaining({ id: 'remind', title: 'Remind Me to Send…' }),
      ],
    },
  ]);
  await fireEvent(menu, 'select', { nativeEvent: { id: 'remind' } });
};
