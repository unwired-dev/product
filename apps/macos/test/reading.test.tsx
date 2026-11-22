import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { fireEvent, render, screen } from '@testing-library/react-native';
import { Settings } from 'react-native';

import { MessageBody } from '../src/message-body.tsx';
import { ReadingSettings } from '../src/reading-settings.tsx';
import { chooseMenuItem, menuItems } from './native-menu.ts';

// The zoom style the reader added to the shown document, if any.
const shownZoom = async () => {
  const webview = await screen.findByTestId('message-webview');
  const html: string = webview.props.source.html;
  return /<style>body\{zoom:[\d.]+\}<\/style>/u.exec(html)?.[0];
};

describe('settings › Reading', () => {
  it('starts at the zoom kept on this Mac and zooms received formatted mail in an open reader', async () => {
    expect.hasAssertions();
    // An earlier launch kept 125%; this file's first reader reads it from user defaults.
    Settings.set({ UnwiredMessageZoom: 125 });
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      content: { html: '<p>Total <b>48 000 CZK</b>, due 30 November.</p>' },
    });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    const app = await render(
      <>
        <ReadingSettings />
        <MessageBody
          inbox={inbox}
          id={id}
        />
      </>,
    );
    try {
      const zoom = screen.getByRole('button', { name: 'Message zoom' });
      const initial = {
        textSize: screen.queryByText('Follows macOS') !== null,
        zoom: zoom.props.accessibilityValue.text,
        footer:
          screen.queryByText(
            'Zooms formatted mail as you read it on this Mac. The message and your Drafts don’t change.',
          ) !== null,
        document: await shownZoom(),
      };
      await fireEvent.press(zoom);
      const offered = menuItems().map(({ title }) => title);
      await chooseMenuItem('150%');
      const zoomed = await shownZoom();
      const webview = await screen.findByTestId('message-webview');
      const message: string = webview.props.source.html;
      await fireEvent.press(
        screen.getByRole('button', { name: 'Message zoom' }),
      );
      await chooseMenuItem('100%');
      expect({
        initial,
        offered,
        zoomed,
        message: message.includes('<b>48 000 CZK</b>'),
        stored: Settings.get('UnwiredMessageZoom'),
        reset: await shownZoom(),
      }).toStrictEqual({
        initial: {
          textSize: true,
          zoom: '125%',
          footer: true,
          document: '<style>body{zoom:1.25}</style>',
        },
        offered: [
          '50%',
          '75%',
          '85%',
          '100%',
          '115%',
          '125%',
          '150%',
          '175%',
          '200%',
          '250%',
          '300%',
        ],
        zoomed: '<style>body{zoom:1.5}</style>',
        message: true,
        stored: 100,
        reset: undefined,
      });
    } finally {
      await app.unmount();
    }
  });
});
