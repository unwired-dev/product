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
  expectedInlineContent: boolean;
  id: string;
  messageId: string;
  rawMessage: string;
  subject: string;
}

interface MessageContentManifestFixture {
  expectedAttachmentIndicator: boolean;
  expectedBody: string;
  expectedInlineContent: boolean;
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
  scenarioDirectory = SCENARIO_DIRECTORY,
): Promise<MessageContentFixture[]> {
  const manifest = parseManifest(
    JSON.parse(
      await readFile(path.join(scenarioDirectory, 'manifest.json'), 'utf8'),
    ),
  );
  const fixtures = await Promise.all(
    manifest.fixtures.map(async (fixture) => {
      const rawTemplate = await readFile(
        path.join(scenarioDirectory, fixture.messageFile),
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
        expectedInlineContent: fixture.expectedInlineContent,
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
        ({
          expectedAttachmentIndicator,
          expectedBody,
          expectedInlineContent,
          id,
          subject,
        }) => ({
          expectedAttachmentIndicator,
          expectedBody,
          expectedInlineContent,
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
  if (!isRecord(value)) {
    throw new TypeError('Message-content fixture manifest entry is invalid.');
  }
  const fixture: MessageContentManifestFixture = {
    expectedAttachmentIndicator: manifestBoolean(
      value.expectedAttachmentIndicator,
    ),
    expectedBody: manifestString(value.expectedBody),
    expectedInlineContent: manifestBoolean(value.expectedInlineContent),
    id: manifestString(value.id),
    messageFile: manifestString(value.messageFile),
    messageId: manifestString(value.messageId),
    subject: manifestString(value.subject),
  };
  const valuesAreValid = [
    fixture.expectedBody.length > 0,
    /^[a-z0-9-]+$/u.test(fixture.id),
    fixture.messageFile.endsWith('.eml'),
    path.basename(fixture.messageFile) === fixture.messageFile,
    fixture.messageId.endsWith('@synthetic.invalid'),
    fixture.subject.length > 0,
  ].every(Boolean);
  if (!valuesAreValid) {
    throw new Error('Message-content fixture manifest value is invalid.');
  }
  return fixture;
}

function manifestBoolean(value: unknown): boolean {
  if (typeof value !== 'boolean') {
    throw new TypeError('Message-content fixture manifest entry is invalid.');
  }
  return value;
}

function manifestString(value: unknown): string {
  if (typeof value !== 'string') {
    throw new TypeError('Message-content fixture manifest entry is invalid.');
  }
  return value;
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
