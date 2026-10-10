import type { RemoteContentSettingsStore } from '@private-email/mail-core/remote-content';

import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createRemoteContentSettings } from '@private-email/mail-core/remote-content';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import * as Schema from 'effect/Schema';
import { ScrollView, View } from 'react-native';

import { GmailMessageBody, ReaderScrollView } from '../src/message-body.tsx';
import { RemoteContentContext } from '../src/remote-content.tsx';

// A 1×1 PNG served by the controlled image server.
const photo =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
const source = 'https://images.example/photo.png';
const decodeUpdates = Schema.decodeSync(
  Schema.fromJsonString(Schema.Array(Schema.String)),
);

// The reader's document starts 200 points into the scroll content. Jest's React Native mocks
// share untyped native method stubs, so the stubs are typed loosely here.
/* oxlint-disable typescript/no-unsafe-type-assertion -- Untyped Jest native method stubs. */
const placeDocument = (queued?: Array<(...values: number[]) => void>) => {
  jest
    .spyOn(ScrollView.prototype as never, 'getNativeScrollRef')
    .mockReturnValue({} as never);
  jest.spyOn(View.prototype as never, 'measureLayout').mockImplementation(((
    _relative: unknown,
    success: (...values: number[]) => void,
  ) => {
    if (queued === undefined) {
      success(0, 200, 320, 400);
    } else {
      queued.push(success);
    }
  }) as never);
};
/* oxlint-enable typescript/no-unsafe-type-assertion */

const settingsWith = (stored: string | null) =>
  createRemoteContentSettings({
    remoteContentSettings: () => Promise.resolve({ settings: stored }),
    setRemoteContentSettings: () => Promise.resolve(null),
    clearRemoteContent: () => Promise.resolve(null),
  });

const measured = (top: number) => ({
  contentSize: { width: 320, height: 400 },
  remoteImages: [{ index: 0, top, bottom: top + 100 }],
});

async function openReader(
  settings: RemoteContentSettingsStore,
  html = `<p>Weekly news</p><img src="${source}" alt="Photo">`,
) {
  const gmail = createSyntheticGmail();
  gmail.serveRemote(source, { data: photo });
  const id = gmail.deliver({
    content: { html },
  });
  const inbox = createGmailInbox(gmail.native);
  await inbox.load();
  const app = await render(
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
  // The reader's scroll view is the only host element above the message.
  const scroll = screen.root;
  if (scroll === null) {
    throw new Error('Expected the reader to render');
  }
  await act(() => {
    fireEvent(scroll, 'layout', { nativeEvent: { layout: { height: 600 } } });
  });
  return { gmail, app, scroll };
}

const finishMeasurement = (queued: Array<(...values: number[]) => void>) => {
  const callback = queued.shift();
  if (callback === undefined) {
    throw new Error('Expected a queued native measurement');
  }
  // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Exercise React Native’s actual deferred layout callback.
  callback(0, 200, 320, 400);
};

// Rendered host/store journeys: only WebKit's measurement and the image server are substituted.
describe('remote message content in the reader', () => {
  /* oxlint-disable vitest/max-expects -- One reader journey checks consent, navigation identity and reversible local nodes. */
  it('loads and hides local image nodes without replacing the mounted document', async () => {
    expect.hasAssertions();
    placeDocument();
    const settings = settingsWith(null);
    await settings.load();
    const { gmail, app } = await openReader(settings);
    try {
      const webview = await screen.findByTestId('message-webview');
      await act(() => {
        fireEvent(webview, 'contentSizeChange', { nativeEvent: measured(0) });
      });
      // Under Ask, nothing is fetched until the person chooses Load images.
      expect(gmail.remoteFetches).toStrictEqual([]);
      const navigation = webview.props.source;
      await act(() => {
        fireEvent.press(screen.getByRole('button', { name: 'Load images' }));
      });
      expect(gmail.remoteFetches).toStrictEqual([source]);
      const loaded = await screen.findByTestId('message-webview');
      expect(loaded).toBe(webview);
      expect(loaded.props.source).toBe(navigation);
      expect(navigation.html).not.toContain('src="data:image/png;base64,');
      const nodes = decodeUpdates(
        loaded.props.nativeConfig.props.remoteImageUpdates,
      );
      expect(nodes).toHaveLength(1);
      expect(nodes[0]).toContain('<img data-remote="0"');
      expect(nodes[0]).toContain('src="data:image/png;base64,');
      expect(nodes[0]).not.toContain('images.example');
      expect(screen.queryByRole('button', { name: 'Load images' })).toBeNull();

      await act(() => settings.setPolicy('never'));
      const hidden = await screen.findByTestId('message-webview');
      expect(hidden).toBe(webview);
      expect(hidden.props.source).toBe(navigation);
      const blocked = decodeUpdates(
        hidden.props.nativeConfig.props.remoteImageUpdates,
      );
      expect(blocked[0]).toContain('data-remote="0"');
      expect(blocked[0]).not.toContain('<img');
      expect(blocked[0]).not.toContain('src=');
      expect(gmail.remoteFetches).toStrictEqual([source]);
    } finally {
      await app.unmount();
    }
  });

  /* oxlint-enable vitest/max-expects */

  it('fetches one normalized resource for every admitted equivalent occurrence', async () => {
    expect.hasAssertions();
    placeDocument();
    const settings = settingsWith(null);
    await settings.load();
    const { gmail, app } = await openReader(
      settings,
      '<p>Photos</p><img src="HTTPS://IMAGES.EXAMPLE:443/photo.png#one"><img src="https://images.example/photo.png#two"><img src="https://images.example/photo.png">',
    );
    try {
      const webview = await screen.findByTestId('message-webview');
      await act(() => {
        fireEvent(webview, 'contentSizeChange', {
          nativeEvent: {
            ...measured(0),
            remoteImages: [0, 1, 2].map((index) => ({
              index,
              top: 0,
              bottom: 100,
            })),
          },
        });
      });
      await act(() => {
        fireEvent.press(screen.getByRole('button', { name: 'Load images' }));
      });
      expect(gmail.remoteFetches).toStrictEqual([source]);
      const nodes = decodeUpdates(
        webview.props.nativeConfig.props.remoteImageUpdates,
      );
      expect(nodes).toHaveLength(3);
      expect(
        nodes.map((node) => /<img data-remote="\d"/u.exec(node)?.[0]),
      ).toStrictEqual([
        '<img data-remote="0"',
        '<img data-remote="1"',
        '<img data-remote="2"',
      ]);
      expect(
        nodes.map((node) => node.includes('src="data:image/png;base64,')),
      ).toStrictEqual([true, true, true]);
    } finally {
      await app.unmount();
    }
  });

  it('retires measurements after scrolling away, revoking automatic loading or closing', async () => {
    expect.hasAssertions();
    const queued: Array<(...values: number[]) => void> = [];
    placeDocument(queued);
    const settings = settingsWith('{"policy":"always","overrides":{}}');
    await settings.load();
    const { gmail, app, scroll } = await openReader(settings);
    try {
      const webview = await screen.findByTestId('message-webview');
      await act(() => {
        fireEvent(webview, 'contentSizeChange', { nativeEvent: measured(0) });
      });
      await act(() => {
        fireEvent.scroll(scroll, {
          nativeEvent: {
            contentOffset: { y: 2000 },
            layoutMeasurement: { height: 600 },
          },
        });
      });
      // The earlier near measurement finishes after the newer scroll position.
      await act(() => finishMeasurement(queued));
      expect(gmail.remoteFetches).toStrictEqual([]);
      await act(() => finishMeasurement(queued));
      await act(() => {
        fireEvent.scroll(scroll, {
          nativeEvent: {
            contentOffset: { y: 0 },
            layoutMeasurement: { height: 600 },
          },
        });
      });
      await act(() => settings.setPolicy('ask'));
      await act(() => finishMeasurement(queued));
      expect(gmail.remoteFetches).toStrictEqual([]);
      await act(() => finishMeasurement(queued));
      expect(screen.getByRole('button', { name: 'Load images' })).toBeVisible();
      await act(() => {
        fireEvent.scroll(scroll, {
          nativeEvent: {
            contentOffset: { y: 100 },
            layoutMeasurement: { height: 600 },
          },
        });
      });
      await app.unmount();
      await act(() => finishMeasurement(queued));
      expect(gmail.remoteFetches).toStrictEqual([]);
    } finally {
      await app.unmount();
    }
  });

  it('never loads under Never, and under Always only near the visible range', async () => {
    expect.hasAssertions();
    placeDocument();
    const never = settingsWith(
      '{"policy":"always","overrides":{"connection-a":"never"}}',
    );
    await never.load();
    const blocked = await openReader(never);
    try {
      const webview = await screen.findByTestId('message-webview');
      await act(() => {
        fireEvent(webview, 'contentSizeChange', { nativeEvent: measured(0) });
      });
      expect(blocked.gmail.remoteFetches).toStrictEqual([]);
      expect(screen.queryByRole('button', { name: 'Load images' })).toBeNull();
      expect(
        screen.getByText('Images in this message are not loaded.'),
      ).toBeVisible();
    } finally {
      await blocked.app.unmount();
    }

    const always = settingsWith('{"policy":"always","overrides":{}}');
    await always.load();
    const { gmail, app, scroll } = await openReader(always);
    try {
      const webview = await screen.findByTestId('message-webview');
      // Two viewports below the visible range is outside the one-viewport margin.
      await act(() => {
        fireEvent(webview, 'contentSizeChange', {
          nativeEvent: measured(1800),
        });
      });
      expect(gmail.remoteFetches).toStrictEqual([]);
      await act(() => {
        fireEvent.scroll(scroll, {
          nativeEvent: {
            contentOffset: { y: 900 },
            layoutMeasurement: { height: 600 },
          },
        });
      });
      expect(gmail.remoteFetches).toStrictEqual([source]);
    } finally {
      await app.unmount();
    }
  });
});
