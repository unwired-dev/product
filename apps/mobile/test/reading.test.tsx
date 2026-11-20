import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createRemoteContentSettings } from '@private-email/mail-core/remote-content';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { fireEvent, render, screen } from '@testing-library/react-native';
import { Settings } from 'react-native';

import { GmailMessageBody, ReaderScrollView } from '../src/message-body.tsx';
import { ReadingSettings } from '../src/reading-settings.tsx';
import { RemoteContentContext } from '../src/remote-content.tsx';

// Chooses a level from the Message Zoom row's native pop-up menu.
const chooseZoom = async (level: string) => {
  const menu = screen.getByLabelText(/^Message Zoom: /u);
  const sections: ReadonlyArray<{
    items: ReadonlyArray<{ id: string; title: string }>;
  }> = menu.props.sections;
  const item = sections
    .flatMap((section) => section.items)
    .find(({ title }) => title === level);
  if (item === undefined) {
    throw new Error(`Expected ${level}`);
  }
  await fireEvent(menu, 'select', { nativeEvent: { id: item.id } });
};

const openReader = async () => {
  const gmail = createSyntheticGmail();
  const id = gmail.deliver({
    content: { html: '<table width="640"><tr><td>Invoice</td></tr></table>' },
  });
  const inbox = createInboxStore(gmail.native);
  await inbox.load();
  const settings = createRemoteContentSettings({
    remoteContentSettings: () => Promise.resolve({ settings: null }),
    setRemoteContentSettings: () => Promise.resolve(null),
    clearRemoteContent: () => Promise.resolve(null),
  });
  await settings.load();
  return render(
    <RemoteContentContext value={settings}>
      <ReaderScrollView>
        <GmailMessageBody
          inbox={inbox}
          id={id}
          connection="connection-a"
        />
      </ReaderScrollView>
    </RemoteContentContext>,
  );
};

// WebKit lays the document out at `width` points in a 320pt view.
const measure = async (width: number) => {
  const webview = await screen.findByTestId('message-webview');
  // The document's container reports the view's width.
  await fireEvent(webview.parent ?? webview, 'layout', {
    nativeEvent: { layout: { width: 320 } },
  });
  await fireEvent(webview, 'contentSizeChange', {
    nativeEvent: { contentSize: { width, height: 400 } },
  });
  return screen.findByTestId('message-webview');
};

describe('settings › Reading', () => {
  it('zooms received formatted mail, fits wide mail only when asked, and keeps both choices on this device', async () => {
    expect.hasAssertions();
    const settings = await render(<ReadingSettings destination="reading" />);
    const initial = {
      textSize: screen.queryByText('Follows iOS') !== null,
      zoom: screen.getByLabelText(/^Message Zoom: /u).props.accessibilityLabel,
      fit: screen.getByLabelText('Fit Wide Messages to the Screen').props.value,
      footer:
        screen.queryByText(
          'Zooms formatted mail as you read it on this iPhone. The message and your Drafts don’t change.',
        ) !== null,
    };
    await chooseZoom('150%');
    await settings.unmount();

    // A 640pt-wide message at 150% scrolls sideways while Fit Wide Messages is off.
    const reader = await openReader();
    const zoomed = await measure(960);
    const unfitted = {
      zoom: zoomed.props.source.html.includes('<style>body{zoom:1.5}</style>'),
      scrolls: zoomed.props.scrollEnabled,
    };
    await reader.unmount();

    await render(<ReadingSettings destination="reading" />);
    await fireEvent(
      screen.getByLabelText('Fit Wide Messages to the Screen'),
      'valueChange',
      true,
    );
    await screen.findByLabelText('Message Zoom: 150%');
    await openReader();
    // The same message is laid out again at the zoom that fits its 320pt view.
    const fitted = await measure(960);
    const refitted = await measure(320);

    expect({
      initial,
      unfitted,
      fitted: fitted.props.source.html.match(/body\{zoom:[\d.]+\}/u)?.[0],
      scrolls: refitted.props.scrollEnabled,
      kept: [
        Settings.get('UnwiredMessageZoom'),
        Settings.get('UnwiredFitWideMessages'),
      ],
    }).toStrictEqual({
      initial: {
        textSize: true,
        zoom: 'Message Zoom: 100%',
        fit: false,
        footer: true,
      },
      unfitted: { zoom: true, scrolls: true },
      fitted: 'body{zoom:0.5}',
      scrolls: false,
      kept: [150, true],
    });
  });
});
