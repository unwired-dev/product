import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, render, screen } from '@testing-library/react-native';

import { GmailMessageBody } from '../src/message-body.tsx';

const png = [
  ...Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAL0lEQVR4nO3OIQEAAAgDMKIQhag0hRg3E/Or3rmkEhAQEBAQEBAQEBAQEBAQSAceG7H8ahi5NXgAAAAASUVORK5CYII=',
    'base64',
  ),
];

// Gmail refuses image downloads until `allow` is called, as after an expired authorization.
const refuseImages = (gmail: ReturnType<typeof createSyntheticGmail>) => {
  const request = gmail.native.gmailRequest;
  let refused = true;
  gmail.native.gmailRequest = (...args) =>
    refused && args[0].includes('/attachments/')
      ? Promise.resolve({ status: 401, body: '{}' })
      : request(...args);
  return () => {
    refused = false;
  };
};

// A rendered host/store test. Only WebKit is substituted.
describe('rich message failure', () => {
  it('renders a replacement presentation after the failed one falls back', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      at: Date.UTC(2020, 0, 1),
      content: {
        html: '<p>Logo below</p><img src="cid:logo" alt="Logo" width="32" height="32">',
        images: [{ contentId: 'logo', mimeType: 'image/png', bytes: png }],
      },
    });
    const allow = refuseImages(gmail);
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const app = await render(
      <GmailMessageBody
        inbox={inbox}
        id={id}
      />,
    );
    try {
      const failed = await screen.findByTestId('message-webview');
      expect(failed.props.source.html).toContain('class="blocked-image"');
      await act(() => {
        failed.props.onError();
      });
      expect(screen.queryByTestId('message-webview')).toBeNull();
      allow();
      await act(() => inbox.load());
      const replacement = await screen.findByTestId('message-webview');
      expect(replacement.props.source.html).toContain(
        'src="data:image/png;base64,',
      );
    } finally {
      await app.unmount();
    }
  });
});
