import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import Clipboard from '@react-native-clipboard/clipboard';
import { act, fireEvent, render } from '@testing-library/react-native';
import { Text } from 'react-native';

import { ContextMenu } from '../src/design.tsx';
import { GmailMessageBody } from '../src/message-body.tsx';

type MenuNode = Parameters<typeof fireEvent.press>[0];
const contextMenuOf = (element: MenuNode) => {
  let menu = element.parent;
  while (menu !== null && menu.type !== 'UnwiredContextMenu') {
    menu = menu.parent;
  }
  if (menu === null) {
    throw new Error('Expected the link context menu');
  }
  return menu;
};
const actionOf = (menu: MenuNode, title: string) => {
  const sections: ReadonlyArray<{
    items: ReadonlyArray<{ id: string; title: string }>;
  }> = menu.props.sections;
  const chosen = sections
    .flatMap((section) => section.items)
    .find((item) => item.title === title);
  if (chosen === undefined) {
    throw new Error(`Expected ${title}`);
  }
  return chosen;
};

describe('context menu event ownership', () => {
  it('runs the latest callback for a displayed item after live updates and rejects retired choices', async () => {
    expect.hasAssertions();
    const read = jest.fn(() => Promise.resolve());
    // A live snapshot rebuilds the same action with a new callback while the menu stays open.
    const rebuiltRead = jest.fn(() => Promise.resolve());
    const reply = jest.fn();
    const trash = jest.fn();
    const readItem = {
      key: 'read',
      title: 'Mark as Read',
      symbol: 'envelope.open',
    };
    const app = await render(
      <ContextMenu
        testID="menu"
        sections={[{ items: [{ ...readItem, run: read }] }]}>
        <Text>Message</Text>
      </ContextMenu>,
    );
    try {
      const { id } = actionOf(app.getByTestId('menu'), 'Mark as Read');
      await app.rerender(
        <ContextMenu
          testID="menu"
          sections={[
            {
              items: [
                {
                  key: 'reply',
                  title: 'Reply',
                  symbol: 'arrowshape.turn.up.left',
                  run: reply,
                },
              ],
            },
            { items: [{ ...readItem, run: rebuiltRead }] },
          ]}>
          <Text>Message</Text>
        </ContextMenu>,
      );
      await fireEvent(app.getByTestId('menu'), 'select', {
        nativeEvent: { id },
      });
      await app.rerender(
        <ContextMenu
          testID="menu"
          sections={[
            {
              items: [
                { key: 'trash', title: 'Delete', symbol: 'trash', run: trash },
              ],
            },
          ]}>
          <Text>Message</Text>
        </ContextMenu>,
      );
      await fireEvent(app.getByTestId('menu'), 'select', {
        nativeEvent: { id },
      });
      expect({
        read: read.mock.calls,
        rebuiltRead: rebuiltRead.mock.calls,
        reply: reply.mock.calls,
        trash: trash.mock.calls,
      }).toStrictEqual({ read: [], rebuiltRead: [[]], reply: [], trash: [] });
    } finally {
      await app.unmount();
    }
  });

  it('copies a live link but rejects queued Copy Link input as soon as its mailbox is forgotten', async () => {
    expect.hasAssertions();
    const copy = jest.spyOn(Clipboard, 'setString').mockReturnValue(undefined);
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      content: { html: '<a href="https://example.invalid/plan">the plan</a>' },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const app = await render(
      <GmailMessageBody
        inbox={inbox}
        id={id}
      />,
    );
    try {
      const link = await app.findByRole('link', {
        name: 'Open link: the plan',
      });
      const menu = contextMenuOf(link);
      const chosen = actionOf(menu, 'Copy Link');
      const select: (event: { nativeEvent: { id: string } }) => void =
        menu.props.onSelect;
      const event = { nativeEvent: { id: chosen.id } };
      await act(() => select(event));
      expect(copy).toHaveBeenCalledWith('https://example.invalid/plan');
      copy.mockClear();
      await act(() => {
        inbox.forget();
        select(event);
      });
      expect(copy).not.toHaveBeenCalled();
    } finally {
      await app.unmount();
      copy.mockRestore();
    }
  });
});
