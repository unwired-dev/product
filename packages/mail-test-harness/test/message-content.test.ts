import {
  encodeMessageContentExpectations,
  loadMessageContentFixtures,
} from '../src/message-content.ts';

describe('message-content scenario corpus', () => {
  it('loads the complete synthetic raw-message corpus', async () => {
    expect.assertions(5);
    const fixtures = await loadMessageContentFixtures(
      'https://127.0.0.1:9443/remote-content.png',
    );

    expect(fixtures.map((fixture) => fixture.id)).toStrictEqual([
      'plain-text',
      'html',
      'unicode',
      'inline-content',
      'attachment',
      'remote-content',
      'malformed-displayable',
    ]);
    expect(
      fixtures.every((fixture) =>
        fixture.rawMessage.includes(fixture.expectedBody),
      ),
    ).toBe(true);
    expect(
      fixtures.every((fixture) =>
        fixture.messageId.endsWith('@synthetic.invalid'),
      ),
    ).toBe(true);
    expect(
      fixtures.find((fixture) => fixture.id === 'html')?.rawMessage,
    ).toContain('Content-Type: text/html');
    expect(
      fixtures.find((fixture) => fixture.id === 'unicode')?.rawMessage,
    ).toContain('👋');
  });

  it('contains inline, attachment, remote, and malformed presentation cases', async () => {
    expect.assertions(4);
    const fixtures = await loadMessageContentFixtures(
      'https://127.0.0.1:9443/remote-content.png',
    );

    expect(
      fixtures.find((fixture) => fixture.id === 'inline-content')?.rawMessage,
    ).toContain('Content-ID: <inline-fixture@synthetic.invalid>');
    expect(
      fixtures.find((fixture) => fixture.id === 'attachment'),
    ).toMatchObject({
      expectedAttachmentIndicator: true,
    });
    expect(
      fixtures.find((fixture) => fixture.id === 'remote-content')?.rawMessage,
    ).toContain('https://127.0.0.1:9443/remote-content.png');
    expect(
      fixtures.find((fixture) => fixture.id === 'malformed-displayable')
        ?.rawMessage,
    ).toContain('<strong>Malformed HTML fixture remains readable.<p></body>');
  });

  it('encodes only semantic UI expectations for the test runner', async () => {
    expect.assertions(2);
    const fixtures = await loadMessageContentFixtures(
      'https://127.0.0.1:9443/remote-content.png',
    );
    const encoded = encodeMessageContentExpectations(fixtures);
    const decoded = Buffer.from(encoded, 'base64').toString('utf8');

    expect(JSON.parse(decoded)).toMatchObject({
      fixtures: expect.arrayContaining([
        {
          expectedAttachmentIndicator: false,
          expectedBody: 'Plain text fixture body is readable.',
          id: 'plain-text',
          subject: 'Fixture Plain Text',
        },
      ]),
      scenario: 'message-content',
      schemaVersion: 1,
    });
    expect(decoded).not.toContain('rawMessage');
  });
});
