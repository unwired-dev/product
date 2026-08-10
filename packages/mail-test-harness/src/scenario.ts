import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export type CategorizationCategory =
  | 'Flights'
  | 'Invites'
  | 'Newsletters & Promotions'
  | 'Orders'
  | 'People';

export interface CategorizationFixture {
  expectedCategory: CategorizationCategory | null;
  id: string;
  messageId: string;
  rawMessage: string;
}

export type IncrementalArrivalStage = 'incremental' | 'initial';

export interface IncrementalArrivalFixture {
  id: string;
  messageId: string;
  rawMessage: string;
  replyTo?: string;
  stage: IncrementalArrivalStage;
}

export interface IncrementalArrivalScenario {
  fixtures: IncrementalArrivalFixture[];
  preservedState: {
    fixtureId: string;
    flags: [string, string];
    mailbox: 'INBOX';
  };
  providerDifferences: {
    gmail: {
      arrival: 'history-or-push';
      injection: 'gmail-api';
      observation: 'gmail-api';
    };
    greenmail: {
      arrival: 'manual-refresh';
      injection: 'smtp';
      observation: 'imap';
    };
  };
}

interface CategorizationFixtureDefinition {
  expectedCategory: CategorizationCategory | null;
  file: string;
  id: string;
}

interface CategorizationManifest {
  fixtures: CategorizationFixtureDefinition[];
  schemaVersion: 1;
}

interface IncrementalArrivalFixtureDefinition {
  file: string;
  id: string;
  replyTo?: string;
  stage: IncrementalArrivalStage;
}

interface IncrementalArrivalManifest {
  fixtures: IncrementalArrivalFixtureDefinition[];
  preservedState: IncrementalArrivalScenario['preservedState'];
  providerDifferences: IncrementalArrivalScenario['providerDifferences'];
  schemaVersion: 1;
}

const categorizationRoot = fileURLToPath(
  new URL('../scenarios/categorization/', import.meta.url),
);
const incrementalArrivalRoot = fileURLToPath(
  new URL('../scenarios/incremental-arrival/', import.meta.url),
);
const flaggedFlag = String.raw`\Flagged`;
const seenFlag = String.raw`\Seen`;
const supportedCategories: ReadonlySet<string> = new Set([
  'Flights',
  'Invites',
  'Newsletters & Promotions',
  'Orders',
  'People',
]);

export async function loadCategorizationFixtures(
  runId: string,
  date: Date,
  root = categorizationRoot,
): Promise<CategorizationFixture[]> {
  const resolvedRoot = path.resolve(root);
  const manifest = parseManifest(
    JSON.parse(
      await readFile(path.join(resolvedRoot, 'manifest.json'), 'utf8'),
    ),
  );
  const fixtureIds = new Set<string>();
  const fixtures: CategorizationFixture[] = [];
  for (const definition of manifest.fixtures) {
    if (fixtureIds.has(definition.id)) {
      throw new Error(
        `Categorization fixture id ${definition.id} is duplicated.`,
      );
    }
    fixtureIds.add(definition.id);
    const fixturePath = localEMLPath(
      resolvedRoot,
      definition.file,
      `Categorization fixture ${definition.id}`,
    );
    const messageId = `${runId}.${definition.id}@synthetic.invalid`;
    const template = await readFile(fixturePath, 'utf8');
    const rawMessage = template
      .replaceAll('{{DATE}}', date.toUTCString())
      .replaceAll('{{MESSAGE_ID}}', messageId);
    validateSyntheticMessage(
      `Categorization fixture ${definition.id}`,
      rawMessage,
    );
    fixtures.push({
      expectedCategory: definition.expectedCategory,
      id: definition.id,
      messageId,
      rawMessage,
    });
  }
  return fixtures;
}

export async function loadIncrementalArrivalScenario(
  runId: string,
  date: Date,
  root = incrementalArrivalRoot,
): Promise<IncrementalArrivalScenario> {
  const resolvedRoot = path.resolve(root);
  const manifest = parseIncrementalArrivalManifest(
    JSON.parse(
      await readFile(path.join(resolvedRoot, 'manifest.json'), 'utf8'),
    ),
  );
  const messageIds = new Map(
    manifest.fixtures.map((fixture) => [
      fixture.id,
      `${runId}.${fixture.id}@synthetic.invalid`,
    ]),
  );
  const fixtures: IncrementalArrivalFixture[] = [];
  for (const definition of manifest.fixtures) {
    const fixturePath = localEMLPath(
      resolvedRoot,
      definition.file,
      `Incremental-arrival fixture ${definition.id}`,
    );
    const messageId = messageIds.get(definition.id);
    if (messageId === undefined) {
      throw new Error(
        `Incremental-arrival fixture ${definition.id} has no message identifier.`,
      );
    }
    const replyToMessageId =
      definition.replyTo === undefined
        ? undefined
        : messageIds.get(definition.replyTo);
    if (definition.replyTo !== undefined && replyToMessageId === undefined) {
      throw new Error(
        `Incremental-arrival fixture ${definition.id} references an unknown reply target.`,
      );
    }
    const template = await readFile(fixturePath, 'utf8');
    const rawMessage = template
      .replaceAll('{{DATE}}', date.toUTCString())
      .replaceAll('{{MESSAGE_ID}}', messageId)
      .replaceAll('{{REPLY_TO_MESSAGE_ID}}', replyToMessageId ?? '');
    validateSyntheticMessage(
      `Incremental-arrival fixture ${definition.id}`,
      rawMessage,
    );
    fixtures.push({
      id: definition.id,
      messageId,
      rawMessage,
      replyTo: definition.replyTo,
      stage: definition.stage,
    });
  }
  return {
    fixtures,
    preservedState: manifest.preservedState,
    providerDifferences: manifest.providerDifferences,
  };
}

function parseManifest(value: unknown): CategorizationManifest {
  if (
    !isRecord(value) ||
    value.schemaVersion !== 1 ||
    !Array.isArray(value.fixtures)
  ) {
    throw new Error('Categorization scenario manifest is invalid.');
  }
  const fixtures = value.fixtures.map(
    (fixture): CategorizationFixtureDefinition => {
      if (
        !isRecord(fixture) ||
        typeof fixture.file !== 'string' ||
        typeof fixture.id !== 'string' ||
        !/^[a-z][a-z0-9-]*$/u.test(fixture.id) ||
        !(
          fixture.expectedCategory === null ||
          isCategorizationCategory(fixture.expectedCategory)
        )
      ) {
        throw new Error('Categorization fixture definition is invalid.');
      }
      return {
        expectedCategory: fixture.expectedCategory,
        file: fixture.file,
        id: fixture.id,
      };
    },
  );
  if (
    fixtures.length !== 6 ||
    new Set(fixtures.map((fixture) => fixture.expectedCategory)).size !== 6
  ) {
    throw new Error(
      'Categorization scenario must cover five System Categories and one uncategorized fixture.',
    );
  }
  return { fixtures, schemaVersion: 1 };
}

function parseIncrementalArrivalManifest(
  value: unknown,
): IncrementalArrivalManifest {
  if (
    !isRecord(value) ||
    value.schemaVersion !== 1 ||
    !Array.isArray(value.fixtures) ||
    !isRecord(value.preservedState) ||
    !isRecord(value.providerDifferences)
  ) {
    throw new Error('Incremental-arrival scenario manifest is invalid.');
  }
  const fixtures = parseIncrementalArrivalFixtures(value.fixtures);
  const initialFixtureId = validateIncrementalArrivalComposition(fixtures);
  if (!hasExpectedPreservedState(value.preservedState, initialFixtureId)) {
    throw new Error('Incremental-arrival preserved-state contract is invalid.');
  }
  if (!hasExpectedProviderDifferences(value.providerDifferences)) {
    throw new Error(
      'Incremental-arrival provider differences must declare GreenMail and Gmail behavior.',
    );
  }
  return {
    fixtures,
    preservedState: {
      fixtureId: initialFixtureId,
      flags: [flaggedFlag, seenFlag],
      mailbox: 'INBOX',
    },
    providerDifferences: value.providerDifferences,
    schemaVersion: 1,
  };
}

function parseIncrementalArrivalFixtures(
  values: unknown[],
): IncrementalArrivalFixtureDefinition[] {
  const fixtures = values.map(parseIncrementalArrivalFixture);
  if (new Set(fixtures.map(({ id }) => id)).size !== fixtures.length) {
    throw new Error('Incremental-arrival fixture definition is invalid.');
  }
  return fixtures;
}

function parseIncrementalArrivalFixture(
  fixture: unknown,
): IncrementalArrivalFixtureDefinition {
  if (
    !isRecord(fixture) ||
    typeof fixture.file !== 'string' ||
    typeof fixture.id !== 'string' ||
    !/^[a-z][a-z0-9-]*$/u.test(fixture.id) ||
    (fixture.stage !== 'initial' && fixture.stage !== 'incremental') ||
    !(fixture.replyTo === undefined || typeof fixture.replyTo === 'string')
  ) {
    throw new Error('Incremental-arrival fixture definition is invalid.');
  }
  return {
    file: fixture.file,
    id: fixture.id,
    replyTo: fixture.replyTo,
    stage: fixture.stage,
  };
}

function validateIncrementalArrivalComposition(
  fixtures: readonly IncrementalArrivalFixtureDefinition[],
): string {
  const initial = fixtures.filter((fixture) => fixture.stage === 'initial');
  const [initialFixture] = initial;
  const incremental = fixtures.filter(
    (fixture) => fixture.stage === 'incremental',
  );
  if (
    fixtures.length !== 3 ||
    initial.length !== 1 ||
    initialFixture === undefined ||
    incremental.length !== 2 ||
    incremental.filter((fixture) => fixture.replyTo !== undefined).length !==
      1 ||
    incremental.some(
      (fixture) =>
        fixture.replyTo !== undefined &&
        !initial.some((candidate) => candidate.id === fixture.replyTo),
    )
  ) {
    throw new Error(
      'Incremental-arrival scenario must contain one initial message, one new message, and one reply to the initial message.',
    );
  }
  return initialFixture.id;
}

function hasExpectedPreservedState(
  value: Record<string, unknown>,
  initialFixtureId: string | undefined,
): boolean {
  return (
    value.fixtureId === initialFixtureId &&
    value.mailbox === 'INBOX' &&
    Array.isArray(value.flags) &&
    value.flags.length === 2 &&
    value.flags[0] === flaggedFlag &&
    value.flags[1] === seenFlag
  );
}

function hasExpectedProviderDifferences(
  value: Record<string, unknown>,
): value is IncrementalArrivalScenario['providerDifferences'] {
  const { gmail, greenmail } = value;
  return (
    isRecord(greenmail) &&
    greenmail.arrival === 'manual-refresh' &&
    greenmail.injection === 'smtp' &&
    greenmail.observation === 'imap' &&
    isRecord(gmail) &&
    gmail.arrival === 'history-or-push' &&
    gmail.injection === 'gmail-api' &&
    gmail.observation === 'gmail-api'
  );
}

function localEMLPath(root: string, file: string, fixtureName: string): string {
  const fixturePath = path.resolve(root, file);
  if (
    path.dirname(fixturePath) !== root ||
    path.extname(fixturePath) !== '.eml'
  ) {
    throw new Error(`${fixtureName} must reference one local .eml file.`);
  }
  return fixturePath;
}

function validateSyntheticMessage(
  fixtureName: string,
  rawMessage: string,
): void {
  if (rawMessage.includes('{{')) {
    throw new Error(`${fixtureName} has an unresolved placeholder.`);
  }
  const addresses = rawMessage.match(
    /[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+/giu,
  );
  if (
    addresses === null ||
    addresses.some(
      (address) => !address.toLowerCase().endsWith('@synthetic.invalid'),
    )
  ) {
    throw new Error(
      `${fixtureName} may contain only synthetic.invalid identities.`,
    );
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isCategorizationCategory(
  value: unknown,
): value is CategorizationCategory {
  return typeof value === 'string' && supportedCategories.has(value);
}
