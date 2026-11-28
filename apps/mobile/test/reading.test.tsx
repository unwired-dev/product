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
    content: { html: '<p>Total <b>48 000 CZK</b>, due 30 November.</p>' },
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
      <ReadingSettings
        destination="reading"
        profiles={[]}
      />
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

// The zoom style the reader added to the shown document, if any.
const shownZoom = async () => {
  const webview = await screen.findByTestId('message-webview');
  const html: string = webview.props.source.html;
  return /<style>body\{zoom:[\d.]+\}<\/style>/u.exec(html)?.[0];
};

describe('settings › Reading', () => {
  it('starts at the zoom kept on this device and zooms received formatted mail in the reader', async () => {
    expect.hasAssertions();
    // An earlier launch kept 125%; this file's first reader reads it from user defaults.
    Settings.set({ UnwiredMessageZoom: 125 });
    await openReader();
    const initial = {
      textSize: screen.queryByText('Follows iOS') !== null,
      zoom: screen.getByLabelText(/^Message Zoom: /u).props.accessibilityLabel,
      footer:
        screen.queryByText(
          'Zooms formatted mail as you read it on this iPhone. The message and your Drafts don’t change.',
        ) !== null,
      document: await shownZoom(),
    };
    await chooseZoom('150%');
    const zoomed = await shownZoom();
    const webview = await screen.findByTestId('message-webview');
    const message: string = webview.props.source.html;

    expect({
      initial,
      zoomed,
      label: screen.getByLabelText(/^Message Zoom: /u).props.accessibilityLabel,
      message: message.includes('48 000 CZK'),
      kept: Settings.get('UnwiredMessageZoom'),
    }).toStrictEqual({
      initial: {
        textSize: true,
        zoom: 'Message Zoom: 125%',
        footer: true,
        document: '<style>body{zoom:1.25}</style>',
      },
      zoomed: '<style>body{zoom:1.5}</style>',
      label: 'Message Zoom: 150%',
      message: true,
      kept: 150,
    });
  });

  it('marks received formatted mail to fit the reader until the switch is turned off', async () => {
    expect.hasAssertions();
    await openReader();
    // WebKit shrinks a document carrying the app's fit style to the reader's width.
    const fits = async () => {
      const webview = await screen.findByTestId('message-webview');
      const html: string = webview.props.source.html;
      return html.includes('<style>:root{--unwired-fit:1}');
    };
    const fitSwitch = screen.getByLabelText('Fit Wide Messages to the Screen');
    const initial = { on: fitSwitch.props.value, fits: await fits() };
    await fireEvent(fitSwitch, 'valueChange', false);

    expect({
      initial,
      off: await fits(),
      kept: Settings.get('UnwiredFitWideMessages'),
    }).toStrictEqual({
      initial: { on: true, fits: true },
      off: false,
      kept: false,
    });
  });
});
