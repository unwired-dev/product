import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { fireEvent, render, screen } from '@testing-library/react-native';
import { Settings } from 'react-native';

import { MessageBody } from '../src/message-body.tsx';
import { ReadingSettings } from '../src/reading-settings.tsx';
import { chooseMenuItem, menuItems } from './native-menu.ts';

// The zoom the reader asks WebKit to apply to the mounted document, and that document's source.
const shown = async () => {
  const webview = await screen.findByTestId('message-webview');
  return {
    zoom: webview.props.nativeConfig.props.messageZoom,
    source: webview.props.source,
  };
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
        document: await shown(),
      };
      await fireEvent.press(zoom);
      const offered = menuItems().map(({ title }) => title);
      await chooseMenuItem('150%');
      const zoomed = await shown();
      await fireEvent.press(
        screen.getByRole('button', { name: 'Message zoom' }),
      );
      await chooseMenuItem('100%');
      const reset = await shown();
      expect({
        initial,
        offered,
        zoomed: zoomed.zoom,
        // The mounted navigation stays, so its selection does too; the message is unchanged.
        mounted: zoomed.source === initial.document.source,
        message: zoomed.source.html.includes('<b>48 000 CZK</b>'),
        unstyled: zoomed.source.html.includes('zoom'),
        stored: Settings.get('UnwiredMessageZoom'),
        reset: reset.zoom,
      }).toStrictEqual({
        initial: {
          textSize: true,
          zoom: '125%',
          footer: true,
          document: expect.objectContaining({ zoom: 1.25 }),
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
        zoomed: 1.5,
        mounted: true,
        message: true,
        unstyled: false,
        stored: 100,
        reset: 1,
      });
    } finally {
      await app.unmount();
    }
  });
});
