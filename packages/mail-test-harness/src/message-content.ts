import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCENARIO_DIRECTORY = fileURLToPath(
  new URL('../scenarios/message-content/', import.meta.url),
);
const REMOTE_CONTENT_PLACEHOLDER = '{{REMOTE_CONTENT_URL}}';

export interface MessageContentFixture {
  expectedAttachmentIndicator: boolean;
  expectedBody: string;
  id: string;
  messageId: string;
  rawMessage: string;
  subject: string;
}

interface MessageContentManifestFixture {
  expectedAttachmentIndicator: boolean;
  expectedBody: string;
  id: string;
  messageFile: string;
  messageId: string;
  subject: string;
}

interface MessageContentManifest {
  fixtures: MessageContentManifestFixture[];
  scenario: 'message-content';
  schemaVersion: 1;
}

export async function loadMessageContentFixtures(
  remoteContentURL: string,
): Promise<MessageContentFixture[]> {
  const manifest = parseManifest(
    JSON.parse(
      await readFile(path.join(SCENARIO_DIRECTORY, 'manifest.json'), 'utf8'),
    ),
  );
  const fixtures = await Promise.all(
    manifest.fixtures.map(async (fixture) => {
      const rawTemplate = await readFile(
        path.join(SCENARIO_DIRECTORY, fixture.messageFile),
        'utf8',
      );
      const rawMessage = rawTemplate.replaceAll(
        REMOTE_CONTENT_PLACEHOLDER,
        remoteContentURL,
      );
      assertFixtureHeaders(fixture, rawMessage);
      return {
        expectedAttachmentIndicator: fixture.expectedAttachmentIndicator,
        expectedBody: fixture.expectedBody,
        id: fixture.id,
        messageId: fixture.messageId,
        rawMessage,
        subject: fixture.subject,
      };
    }),
  );
  const uniqueIds = new Set(fixtures.map((fixture) => fixture.id));
  const uniqueMessageIds = new Set(
    fixtures.map((fixture) => fixture.messageId),
  );
  if (
    uniqueIds.size !== fixtures.length ||
    uniqueMessageIds.size !== fixtures.length
  ) {
    throw new Error('Message-content fixture identifiers must be unique.');
  }
  return fixtures;
}

export function encodeMessageContentExpectations(
  fixtures: readonly MessageContentFixture[],
): string {
  return Buffer.from(
    JSON.stringify({
      fixtures: fixtures.map(
        ({ expectedAttachmentIndicator, expectedBody, id, subject }) => ({
          expectedAttachmentIndicator,
          expectedBody,
          id,
          subject,
        }),
      ),
      scenario: 'message-content',
      schemaVersion: 1,
    }),
  ).toString('base64');
}

function parseManifest(value: unknown): MessageContentManifest {
  if (!isRecord(value)) {
    throw new Error('Message-content manifest must be an object.');
  }
  if (value.schemaVersion !== 1 || value.scenario !== 'message-content') {
    throw new Error('Message-content manifest identity is invalid.');
  }
  if (!Array.isArray(value.fixtures) || value.fixtures.length === 0) {
    throw new Error('Message-content manifest must contain fixtures.');
  }
  return {
    fixtures: value.fixtures.map(parseFixture),
    scenario: 'message-content',
    schemaVersion: 1,
  };
}

function parseFixture(value: unknown): MessageContentManifestFixture {
  if (
    !isRecord(value) ||
    typeof value.expectedAttachmentIndicator !== 'boolean' ||
    typeof value.expectedBody !== 'string' ||
    typeof value.id !== 'string' ||
    typeof value.messageFile !== 'string' ||
    typeof value.messageId !== 'string' ||
    typeof value.subject !== 'string'
  ) {
    throw new Error('Message-content fixture manifest entry is invalid.');
  }
  if (
    value.expectedBody.length === 0 ||
    !/^[a-z0-9-]+$/u.test(value.id) ||
    !value.messageFile.endsWith('.eml') ||
    path.basename(value.messageFile) !== value.messageFile ||
    !value.messageId.endsWith('@synthetic.invalid') ||
    value.subject.length === 0
  ) {
    throw new Error('Message-content fixture manifest value is invalid.');
  }
  return {
    expectedAttachmentIndicator: value.expectedAttachmentIndicator,
    expectedBody: value.expectedBody,
    id: value.id,
    messageFile: value.messageFile,
    messageId: value.messageId,
    subject: value.subject,
  };
}

function assertFixtureHeaders(
  fixture: Readonly<MessageContentManifestFixture>,
  rawMessage: string,
): void {
  if (!rawMessage.includes(`Message-ID: <${fixture.messageId}>`)) {
    throw new Error(
      `Message-content fixture ${fixture.id} has the wrong Message-ID.`,
    );
  }
  if (!rawMessage.includes(`Subject: ${fixture.subject}`)) {
    throw new Error(
      `Message-content fixture ${fixture.id} has the wrong Subject.`,
    );
  }
  if (!rawMessage.includes(fixture.expectedBody)) {
    throw new Error(
      `Message-content fixture ${fixture.id} lacks its expected body marker.`,
    );
  }
  if (rawMessage.includes(REMOTE_CONTENT_PLACEHOLDER)) {
    throw new Error(
      `Message-content fixture ${fixture.id} has an unresolved placeholder.`,
    );
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
