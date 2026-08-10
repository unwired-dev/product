import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

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
          expectedInlineContent: false,
          id: 'plain-text',
          subject: 'Fixture Plain Text',
        },
      ]),
      scenario: 'message-content',
      schemaVersion: 1,
    });
    expect(decoded).not.toContain('rawMessage');
  });

  it.each<InvalidScenario>([
    {
      expected: 'Message-content manifest identity is invalid.',
      manifest: validManifest([validManifestFixture()], 2),
      rawFiles: {},
    },
    {
      expected: 'Message-content fixture manifest entry is invalid.',
      manifest: validManifest([manifestFixtureWithoutInlineExpectation()]),
      rawFiles: {},
    },
    {
      expected: 'Message-content fixture manifest value is invalid.',
      manifest: validManifest([
        validManifestFixture({ messageFile: '../escape.eml' }),
      ]),
      rawFiles: {},
    },
    {
      expected: 'Message-content fixture fixture has the wrong Message-ID.',
      manifest: validManifest([validManifestFixture()]),
      rawFiles: {
        'fixture.eml': validRawMessage().replace(
          'Message-ID: <fixture@synthetic.invalid>',
          'Message-ID: <wrong@synthetic.invalid>',
        ),
      },
    },
    {
      expected: 'Message-content fixture identifiers must be unique.',
      manifest: validManifest([validManifestFixture(), validManifestFixture()]),
      rawFiles: { 'fixture.eml': validRawMessage() },
    },
    {
      expected: 'Message-content fixture identifiers must be unique.',
      manifest: validManifest([
        validManifestFixture(),
        validManifestFixture({ id: 'second', messageFile: 'second.eml' }),
      ]),
      rawFiles: {
        'fixture.eml': validRawMessage(),
        'second.eml': validRawMessage(
          validManifestFixture({ id: 'second', messageFile: 'second.eml' }),
        ),
      },
    },
    {
      expected:
        'Message-content fixture fixture has an unresolved placeholder.',
      manifest: validManifest([validManifestFixture()]),
      rawFiles: {
        'fixture.eml': `${validRawMessage()}\r\n{{REMOTE_CONTENT_URL}}`,
      },
      remoteContentURL: '{{REMOTE_CONTENT_URL}}',
    },
  ])(
    'rejects malformed manifest and fixture input: $expected',
    async (testCase) => {
      expect.assertions(1);
      await expectInvalidScenario(testCase);
    },
  );
});

interface ManifestFixture {
  expectedAttachmentIndicator: boolean;
  expectedBody: string;
  expectedInlineContent?: boolean;
  id: string;
  messageFile: string;
  messageId: string;
  subject: string;
}

interface InvalidScenario {
  expected: string;
  manifest: unknown;
  rawFiles: Record<string, string>;
  remoteContentURL?: string;
}

function validManifestFixture(
  overrides: Partial<ManifestFixture> = {},
): ManifestFixture {
  return {
    expectedAttachmentIndicator: false,
    expectedBody: 'Fixture body.',
    expectedInlineContent: false,
    id: 'fixture',
    messageFile: 'fixture.eml',
    messageId: 'fixture@synthetic.invalid',
    subject: 'Fixture Subject',
    ...overrides,
  };
}

function manifestFixtureWithoutInlineExpectation(): ManifestFixture {
  const { expectedInlineContent: _expectedInlineContent, ...fixture } =
    validManifestFixture();
  return fixture;
}

function validManifest(
  fixtures: ManifestFixture[],
  schemaVersion = 1,
): unknown {
  return { fixtures, scenario: 'message-content', schemaVersion };
}

function validRawMessage(fixture = validManifestFixture()): string {
  return [
    'From: sender@synthetic.invalid',
    'To: inbox@synthetic.invalid',
    `Subject: ${fixture.subject}`,
    `Message-ID: <${fixture.messageId}>`,
    '',
    fixture.expectedBody,
  ].join('\r\n');
}

async function withScenario(
  scenario: Pick<InvalidScenario, 'manifest' | 'rawFiles'>,
  operation: (directory: string) => Promise<void>,
): Promise<void> {
  const directory = await mkdtemp(path.join(tmpdir(), 'message-content-'));
  try {
    await writeFile(
      path.join(directory, 'manifest.json'),
      JSON.stringify(scenario.manifest),
    );
    await Promise.all(
      Object.entries(scenario.rawFiles).map(([name, rawMessage]) =>
        writeFile(path.join(directory, name), rawMessage),
      ),
    );
    await operation(directory);
  } finally {
    await rm(directory, { force: true, recursive: true });
  }
}

async function expectInvalidScenario(testCase: InvalidScenario): Promise<void> {
  await withScenario(testCase, async (directory) => {
    await expect(
      loadMessageContentFixtures(
        testCase.remoteContentURL ??
          'https://127.0.0.1:9443/remote-content.png',
        directory,
      ),
    ).rejects.toThrow(testCase.expected);
  });
}
